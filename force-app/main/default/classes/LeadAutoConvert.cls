/**
 * Custom automated Lead Conversion.
 *
 * Triggered when a Lead's Status moves to "IC Completed – Qualified" (without
 * the standard Convert button). Performs a Database.LeadConvert to create the
 * Account / Opportunity / primary Contact, then layers on:
 *   • A Parent record-type Contact for Parent 2 (if Parent_2_* is populated).
 *   • Student record-type Contacts based on No_of_Student_Enrolling_Today__c.
 *
 * The primary Contact (created by LeadConvert from Lead.FirstName / LastName)
 * is updated to the Parent record type and overlaid with Parent_1_* values
 * when those are populated, so the converted Contact reflects the explicit
 * Parent 1 fields rather than whatever the Lead's primary name was.
 *
 * Exposed both as a static method (called from LeadAutoConvertTrigger via a
 * Queueable) and as an @InvocableMethod (callable from Flow) so the same
 * conversion logic backs every entry point.
 */
public with sharing class LeadAutoConvert {

    public static final String QUALIFIED_STATUS = 'IC Completed – Qualified';
    public static final String CONVERTED_STATUS = 'Converted (SOM Scheduled)';

    private static final String CONTACT_RT_PARENT  = 'Parent';
    private static final String CONTACT_RT_STUDENT = 'Student';

    // Opportunity Contact Role values (must match the Role picklist on
    // OpportunityContactRole). Both parents share role "Parent"; the primary
    // contact (Parent 1) is the one flagged IsPrimary=true.
    private static final String OCR_ROLE_PARENT  = 'Parent';
    private static final String OCR_ROLE_STUDENT = 'Student';

    // Stage applied to every freshly-created Opportunity (the one returned
    // by Database.convertLead and any clones we make per enrolling student).
    private static final String OPPORTUNITY_STAGE = 'Ready to Schedule SOM';

    /** Allow tests / data loads to short-circuit the trigger. */
    public static Boolean bypassTrigger = false;

    /**
     * Lead Ids we've already processed in the current Apex transaction.
     * Two record-triggered flows on Lead route to convertLeadsInvocable
     * (Lead_Auto_Convert on Status→Qualified, Lead_Manual_Convert_Extras
     * on IsConverted false→true). When the auto path runs, its own
     * Database.convertLead flips IsConverted, which causes the manual-path
     * flow to fire AFTER the auto flow returns — at which point bypassTrigger
     * has already been reset. This static set carries forward across the
     * separate flow firings in the same transaction so we don't double-create
     * the Parent 2 + Student contacts.
     */
    private static Set<Id> processedLeadIds = new Set<Id>();

    // ─── Invocable entry point (Flow) ──────────────────────────────
    /**
     * Single invocable used by both record-triggered flows on Lead. Auto-
     * routes each Lead based on its current IsConverted state:
     *   • IsConverted = false → convertLeads (Database.convertLead + extras)
     *   • IsConverted = true  → createExtrasForConvertedLeads (extras only,
     *     for the standard Convert UI button path)
     *
     * Wraps both calls in bypassTrigger so the inner Database.convertLead's
     * own Lead update doesn't cause a flow to re-enter this invocable.
     */
    @InvocableMethod(
        label='Convert Qualified Leads'
        description='Converts the given Leads (or, if already converted, just lays down Parent 2 + Student contacts).'
    )
    public static void convertLeadsInvocable(List<Id> leadIds) {
        if (bypassTrigger) return;
        if (leadIds == null || leadIds.isEmpty()) return;

        Set<Id> ids = new Set<Id>(leadIds);
        // Skip leads we've already handled in this transaction so the manual-
        // convert flow doesn't recreate extras after the auto-convert flow.
        ids.removeAll(processedLeadIds);
        if (ids.isEmpty()) return;

        Set<Id> notYetConverted  = new Set<Id>();
        Set<Id> alreadyConverted = new Set<Id>();
        for (Lead l : [SELECT Id, IsConverted FROM Lead WHERE Id IN :ids]) {
            if (l.IsConverted) alreadyConverted.add(l.Id);
            else               notYetConverted.add(l.Id);
        }

        processedLeadIds.addAll(ids);
        bypassTrigger = true;
        try {
            if (!notYetConverted.isEmpty())  convertLeads(notYetConverted);
            if (!alreadyConverted.isEmpty()) createExtrasForConvertedLeads(alreadyConverted);
        } finally {
            bypassTrigger = false;
        }
    }

    // ─── Main entry point: status-change auto-convert path ────────────
    public static void convertLeads(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) return;

        List<Lead> leads = queryLeadsForConvert(leadIds, false);
        if (leads.isEmpty()) return;

        // Step 0 — pre-convert dedup. If an existing Contact matches by Email
        // (or an existing Account matches by Name), wire those Ids into the
        // LeadConvert call so Salesforce reuses the existing records instead
        // of failing with DUPLICATES_DETECTED. Same for Opportunity by
        // Account + Name — if matched, skip Opp creation entirely.
        Map<Id, Id> matchedContactByLead = new Map<Id, Id>();
        Map<Id, Id> matchedAccountByLead = new Map<Id, Id>();
        Map<Id, Id> matchedOppByLead     = new Map<Id, Id>();
        findExistingMatches(leads, matchedContactByLead, matchedAccountByLead, matchedOppByLead);

        // Step 1 — bulk Database.LeadConvert.
        List<Database.LeadConvert> convertCalls = new List<Database.LeadConvert>();
        for (Lead l : leads) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(l.Id);
            lc.setConvertedStatus(CONVERTED_STATUS);
            if (matchedContactByLead.containsKey(l.Id)) lc.setContactId(matchedContactByLead.get(l.Id));
            if (matchedAccountByLead.containsKey(l.Id)) lc.setAccountId(matchedAccountByLead.get(l.Id));
            // If we already have an Opp on the matched Account, don't make a
            // duplicate. We still link OCRs to the existing one downstream.
            lc.setDoNotCreateOpportunity(matchedOppByLead.containsKey(l.Id));
            convertCalls.add(lc);
        }
        // allOrNone=false so a single bad Lead doesn't poison the rest.
        List<Database.LeadConvertResult> results = Database.convertLead(convertCalls, false);

        Map<Id, Id> accountIdByLeadId     = new Map<Id, Id>();
        Map<Id, Id> contactIdByLeadId     = new Map<Id, Id>();
        Map<Id, Id> opportunityIdByLeadId = new Map<Id, Id>();
        for (Database.LeadConvertResult r : results) {
            if (r.isSuccess()) {
                accountIdByLeadId.put(r.getLeadId(), r.getAccountId());
                contactIdByLeadId.put(r.getLeadId(), r.getContactId());
                Id oppFromConvert = r.getOpportunityId();
                if (oppFromConvert != null) {
                    opportunityIdByLeadId.put(r.getLeadId(), oppFromConvert);
                } else if (matchedOppByLead.containsKey(r.getLeadId())) {
                    // setDoNotCreateOpportunity(true) → use the matched existing one.
                    opportunityIdByLeadId.put(r.getLeadId(), matchedOppByLead.get(r.getLeadId()));
                }
            } else {
                System.debug(LoggingLevel.WARN,
                    'LeadAutoConvert: convertLead failed for Lead ' + r.getLeadId() + ' — ' + r.getErrors());
            }
        }
        if (accountIdByLeadId.isEmpty()) return;

        // Step 2 — primary-contact overlay + Parent 2 + Student contacts.
        Map<Id, FamilyExtras> familyByLead = applyPostConvertContacts(leads, accountIdByLeadId, contactIdByLeadId);

        // Step 3 — clone the freshly-created Opportunity once per additional
        // enrolling student so each Opp pairs to a single student.
        Map<Id, Map<Integer, Id>> oppIdBySlotByLead = cloneOpportunitiesForAdditionalStudents(
            leads, opportunityIdByLeadId, matchedOppByLead, familyByLead);

        // Step 4 — Per-Opp OCRs FIRST: Parent 1 (Parent + IsPrimary), Parent 2
        // (Parent), and only this slot's student (Student). Inserted before
        // Step 5 so the subsequent Opp Update can trigger the
        // "Opportunity Name From Student OCR" flow with all OCRs in place.
        syncOpportunityContactRolesPerOpp(leads, contactIdByLeadId, familyByLead, oppIdBySlotByLead);

        // Step 5 — set StageName on each freshly-created Opp. This Opp Update
        // event triggers the OCR-driven rename flow now that the Student OCR
        // exists from Step 4.
        setOpportunityStagePerSlot(leads, oppIdBySlotByLead, matchedOppByLead);
    }

    // ─── Standard "Convert" button path ───────────────────────────────
    /**
     * Called from the trigger when a Lead transitions from IsConverted=false
     * to IsConverted=true outside our auto-convert path (i.e. the user clicked
     * the standard Convert button). The Lead is already converted at this
     * point — Salesforce has populated ConvertedAccountId / ConvertedContactId
     * — so we skip Database.convertLead and just layer on the Parent 1
     * overlay + Parent 2 + Student contacts using the same logic as the
     * automated path.
     */
    public static void createExtrasForConvertedLeads(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) return;

        List<Lead> leads = queryLeadsForConvert(leadIds, true);
        if (leads.isEmpty()) return;

        Map<Id, Id> accountIdByLeadId     = new Map<Id, Id>();
        Map<Id, Id> contactIdByLeadId     = new Map<Id, Id>();
        Map<Id, Id> opportunityIdByLeadId = new Map<Id, Id>();
        for (Lead l : leads) {
            if (l.ConvertedAccountId != null)     accountIdByLeadId.put(l.Id, l.ConvertedAccountId);
            if (l.ConvertedContactId != null)     contactIdByLeadId.put(l.Id, l.ConvertedContactId);
            if (l.ConvertedOpportunityId != null) opportunityIdByLeadId.put(l.Id, l.ConvertedOpportunityId);
        }
        if (accountIdByLeadId.isEmpty()) return;

        Map<Id, FamilyExtras> familyByLead = applyPostConvertContacts(leads, accountIdByLeadId, contactIdByLeadId);
        // Manual-button path: no pre-convert dedup ran, so we treat every
        // primary Opp as a freshly-created one and clone / OCR-sync / Stage
        // it the same way as the auto path. OCRs go first so the subsequent
        // Stage update triggers the rename flow with the Student OCR in place.
        Map<Id, Map<Integer, Id>> oppIdBySlotByLead = cloneOpportunitiesForAdditionalStudents(
            leads, opportunityIdByLeadId, null, familyByLead);
        syncOpportunityContactRolesPerOpp(leads, contactIdByLeadId, familyByLead, oppIdBySlotByLead);
        setOpportunityStagePerSlot(leads, oppIdBySlotByLead, null);
    }

    // ─── Shared helpers ───────────────────────────────────────────────
    /**
     * @param convertedFlag  true to query already-converted leads (and pull
     *                       ConvertedAccountId / ConvertedContactId), false
     *                       for the pre-convert auto path.
     */
    private static List<Lead> queryLeadsForConvert(Set<Id> leadIds, Boolean convertedFlag) {
        if (convertedFlag) {
            return [
                SELECT Id, FirstName, LastName, Email, Phone, MobilePhone, Company,
                       Status, IsConverted, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId,
                       Parent_1_Name_First_Last__c, Parent_1_Email__c, Parent_1_Phone__c, Parent_1_ID__c,
                       Parent_2_Name_First_Last__c, Parent_2_Email__c, Parent_2_Phone__c, Parent_2_ID__c,
                       Second_Adult_Type__c,
                       No_of_Student_Enrolling_Today__c,
                       Student_Name__c, Student_Email__c, Student_s_Current_Grade__c, Student_ID_1__c,
                       Student_2_Name__c, Student_2_Email__c, Student_2_Grade__c, Student_ID_2__c,
                       Student_3_Name__c, Student_3_Email__c, Student_3_Grade__c, Student_ID_3__c
                FROM Lead
                WHERE Id IN :leadIds AND IsConverted = true
            ];
        }
        return [
            SELECT Id, FirstName, LastName, Email, Phone, MobilePhone, Company,
                   Status, IsConverted,
                   Parent_1_Name_First_Last__c, Parent_1_Email__c, Parent_1_Phone__c, Parent_1_ID__c,
                   Parent_2_Name_First_Last__c, Parent_2_Email__c, Parent_2_Phone__c, Parent_2_ID__c,
                   Second_Adult_Type__c,
                   No_of_Student_Enrolling_Today__c,
                   Student_Name__c, Student_Email__c, Student_s_Current_Grade__c, Student_ID_1__c,
                   Student_2_Name__c, Student_2_Email__c, Student_2_Grade__c, Student_ID_2__c,
                   Student_3_Name__c, Student_3_Email__c, Student_3_Grade__c, Student_ID_3__c
            FROM Lead
            WHERE Id IN :leadIds AND IsConverted = false
        ];
    }

    /**
     * Builds + writes the Parent 1 overlay, Parent 2, and Student contacts
     * for a set of leads that have already been converted (either via our
     * Database.convertLead call or via the standard Convert button).
     *
     * Both DML calls run with:
     *   • DuplicateRuleHeader.AllowSave = true → bypass duplicate rules
     *     (e.g. "Email Match Contact") that would otherwise throw
     *     DUPLICATES_DETECTED and roll back the whole transaction.
     *   • allOrNone = false → if a single row fails for any other reason
     *     (validation rule, FLS, etc.), the rest still commit.
     */
    private static Map<Id, FamilyExtras> applyPostConvertContacts(List<Lead> leads,
                                                                  Map<Id, Id> accountIdByLeadId,
                                                                  Map<Id, Id> contactIdByLeadId) {
        Map<String, Id> contactRtByName = getContactRecordTypeMap();

        // Pre-query existing contacts on each target Account so we can dedup
        // Parent 2 / Student rows by (FirstName | LastName | Email) and reuse
        // the existing Contact's Id for OCR creation.
        Set<Id> targetAccountIds = new Set<Id>();
        for (Id aId : accountIdByLeadId.values()) if (aId != null) targetAccountIds.add(aId);
        Map<Id, Map<String, Id>> existingByAccountByKey = new Map<Id, Map<String, Id>>();
        if (!targetAccountIds.isEmpty()) {
            for (Contact existing : [
                SELECT Id, AccountId, FirstName, LastName, Email
                FROM Contact
                WHERE AccountId IN :targetAccountIds
            ]) {
                Map<String, Id> byKey = existingByAccountByKey.get(existing.AccountId);
                if (byKey == null) {
                    byKey = new Map<String, Id>();
                    existingByAccountByKey.put(existing.AccountId, byKey);
                }
                byKey.put(contactDedupeKey(existing.FirstName, existing.LastName, existing.Email), existing.Id);
            }
        }

        List<Contact> primaryUpdates  = new List<Contact>();
        List<Contact> extraContacts   = new List<Contact>();
        Map<Id, List<ExtraRow>> extrasByLead = new Map<Id, List<ExtraRow>>();

        for (Lead l : leads) {
            Id accountId = accountIdByLeadId.get(l.Id);
            Id primaryContactId = contactIdByLeadId.get(l.Id);
            if (accountId == null) continue;

            if (primaryContactId != null) {
                primaryUpdates.add(buildPrimaryContactUpdate(primaryContactId, l, contactRtByName));
            }

            Map<String, Id> existingForAccount = existingByAccountByKey.get(accountId);
            if (existingForAccount == null) existingForAccount = new Map<String, Id>();
            List<ExtraRow> rowsForLead = new List<ExtraRow>();

            if (String.isNotBlank(l.Parent_2_Name_First_Last__c)) {
                Contact c = buildParent2Contact(accountId, l, contactRtByName);
                rowsForLead.add(buildExtraRow(c, OCR_ROLE_PARENT, null, existingForAccount, extraContacts));
            }
            // Build students slot-by-slot so we can carry the slot through to
            // the multi-Opp logic downstream (each Opp pairs to one slot).
            Integer cap = parseStudentCount(l.No_of_Student_Enrolling_Today__c);
            for (Integer slot = 1; slot <= 3 && slot <= cap; slot++) {
                String studentName = getStudentNameForSlot(l, slot);
                if (String.isBlank(studentName)) continue;
                Contact c = buildStudentContact(accountId, l, slot, contactRtByName);
                rowsForLead.add(buildExtraRow(c, OCR_ROLE_STUDENT, slot, existingForAccount, extraContacts));
            }
            extrasByLead.put(l.Id, rowsForLead);
        }

        if (!primaryUpdates.isEmpty()) {
            applyAllowDuplicateOptions(primaryUpdates);
            Database.SaveResult[] updateResults = Database.update(primaryUpdates, false);
            logSaveErrors('Primary Contact update', updateResults);
        }
        if (!extraContacts.isEmpty()) {
            applyAllowDuplicateOptions(extraContacts);
            Database.SaveResult[] insertResults = Database.insert(extraContacts, false);
            logSaveErrors('Extra Contact insert', insertResults);

            Integer idx = 0;
            for (Contact c : extraContacts) {
                Database.SaveResult sr = insertResults[idx++];
                if (!sr.isSuccess()) continue;
                for (List<ExtraRow> rows : extrasByLead.values()) {
                    for (ExtraRow row : rows) {
                        if (row.contact === c) row.contactId = sr.getId();
                    }
                }
            }
        }

        // Collapse the row list into a per-Lead FamilyExtras struct so the
        // multi-Opp / OCR phases can look up Parent 2 and per-slot students
        // without walking ExtraRow lists again.
        Map<Id, FamilyExtras> familyByLead = new Map<Id, FamilyExtras>();
        for (Lead l : leads) {
            FamilyExtras fe = new FamilyExtras();
            List<ExtraRow> rows = extrasByLead.get(l.Id);
            if (rows != null) {
                for (ExtraRow row : rows) {
                    if (row.contactId == null) continue;
                    if (row.ocrRole == OCR_ROLE_PARENT) {
                        fe.parent2ContactId = row.contactId;
                    } else if (row.ocrRole == OCR_ROLE_STUDENT && row.studentSlot != null) {
                        fe.studentContactIdBySlot.put(row.studentSlot, row.contactId);
                    }
                }
            }
            familyByLead.put(l.Id, fe);
        }
        return familyByLead;
    }

    /** Pairs an extra Contact with the OCR role we want on the Opportunity. */
    private class ExtraRow {
        Contact contact;     // null when we're reusing an existing Contact
        Id      contactId;   // populated either from dedup or from insert result
        String  ocrRole;
        Integer studentSlot; // 1, 2, or 3 for Student rows; null for Parent 2
    }

    /**
     * Per-Lead view of the family contacts the convert process touched, used
     * to drive per-Opportunity OCR creation. studentContactIdBySlot maps the
     * Lead's student slot (1/2/3) to the Contact Id that represents that
     * student — only slots whose name field was populated appear here.
     */
    private class FamilyExtras {
        Id parent2ContactId;
        Map<Integer, Id> studentContactIdBySlot = new Map<Integer, Id>();
    }

    private static ExtraRow buildExtraRow(Contact c, String ocrRole, Integer studentSlot, Map<String, Id> existingForAccount, List<Contact> extraContactsToInsert) {
        ExtraRow row = new ExtraRow();
        row.ocrRole = ocrRole;
        row.studentSlot = studentSlot;
        Id existingId = existingForAccount.get(contactDedupeKey(c.FirstName, c.LastName, c.Email));
        if (existingId != null) {
            // Reuse the existing Contact — don't create a duplicate.
            row.contactId = existingId;
        } else {
            // New contact will be inserted; its Id is filled in after DML.
            row.contact = c;
            extraContactsToInsert.add(c);
        }
        return row;
    }

    private static String contactDedupeKey(String fn, String ln, String em) {
        String f = fn == null ? '' : fn.toLowerCase().trim();
        String l = ln == null ? '' : ln.toLowerCase().trim();
        String e = em == null ? '' : em.toLowerCase().trim();
        return f + '|' + l + '|' + e;
    }

    /**
     * Pre-convert dedup. For each Lead, populate (where matched):
     *   • matchedContactByLead : existing Contact Id (matched by Email).
     *     The Contact's AccountId is also added to matchedAccountByLead.
     *   • matchedAccountByLead : existing Account Id (matched by Name = Lead.Company),
     *     used only when no Contact match was found.
     *   • matchedOppByLead     : existing open Opportunity on the matched Account
     *     whose Name matches Lead.Company (best-effort; can be tightened later).
     *
     * Wiring these onto Database.LeadConvert prevents DUPLICATES_DETECTED
     * errors when the family already has Account/Contact/Opp records.
     */
    @TestVisible
    private static void findExistingMatches(List<Lead> leads,
                                            Map<Id, Id> matchedContactByLead,
                                            Map<Id, Id> matchedAccountByLead,
                                            Map<Id, Id> matchedOppByLead) {
        Set<String> emails    = new Set<String>();
        Set<String> companies = new Set<String>();
        for (Lead l : leads) {
            if (String.isNotBlank(l.Email))   emails.add(l.Email.toLowerCase());
            if (String.isNotBlank(l.Company)) companies.add(l.Company);
        }

        Map<String, Contact> contactByEmail = new Map<String, Contact>();
        if (!emails.isEmpty()) {
            for (Contact c : [SELECT Id, AccountId, Email FROM Contact WHERE Email != null AND Email IN :emails]) {
                String key = c.Email.toLowerCase();
                if (!contactByEmail.containsKey(key)) contactByEmail.put(key, c);
            }
        }

        Map<String, Id> accountIdByName = new Map<String, Id>();
        if (!companies.isEmpty()) {
            for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :companies]) {
                if (!accountIdByName.containsKey(a.Name)) accountIdByName.put(a.Name, a.Id);
            }
        }

        for (Lead l : leads) {
            Id resolvedAccountId;

            if (String.isNotBlank(l.Email)) {
                Contact mc = contactByEmail.get(l.Email.toLowerCase());
                if (mc != null) {
                    matchedContactByLead.put(l.Id, mc.Id);
                    if (mc.AccountId != null) resolvedAccountId = mc.AccountId;
                }
            }
            if (resolvedAccountId == null && String.isNotBlank(l.Company)) {
                resolvedAccountId = accountIdByName.get(l.Company);
            }
            if (resolvedAccountId != null) {
                matchedAccountByLead.put(l.Id, resolvedAccountId);
            }
        }

        // Look for an existing open Opp on each matched Account whose Name
        // matches the Lead's Company. Skip Opp creation in that case.
        Set<Id> resolvedAccountIds = new Set<Id>(matchedAccountByLead.values());
        if (resolvedAccountIds.isEmpty()) return;

        Map<Id, List<Opportunity>> oppsByAccount = new Map<Id, List<Opportunity>>();
        for (Opportunity o : [
            SELECT Id, Name, AccountId FROM Opportunity
            WHERE AccountId IN :resolvedAccountIds AND IsClosed = false
        ]) {
            List<Opportunity> opps = oppsByAccount.get(o.AccountId);
            if (opps == null) {
                opps = new List<Opportunity>();
                oppsByAccount.put(o.AccountId, opps);
            }
            opps.add(o);
        }
        for (Lead l : leads) {
            Id accId = matchedAccountByLead.get(l.Id);
            if (accId == null) continue;
            List<Opportunity> opps = oppsByAccount.get(accId);
            if (opps == null || opps.isEmpty()) continue;
            // Prefer a Name match (e.g. "<Company>"); fall back to the first open Opp.
            Opportunity pick;
            if (String.isNotBlank(l.Company)) {
                for (Opportunity o : opps) {
                    if (o.Name == l.Company) { pick = o; break; }
                }
            }
            if (pick == null) pick = opps[0];
            matchedOppByLead.put(l.Id, pick.Id);
        }
    }

    /**
     * Per-Opportunity OCR sync. Idempotent — fixes the Role / IsPrimary flag
     * on the auto-created primary OCR (when LeadConvert creates one) and
     * inserts the rest. For each (Lead, slot) pair:
     *
     *   Primary Contact (Parent 1)  → Role = "Parent", IsPrimary = true
     *   Parent 2 (if present)       → Role = "Parent", IsPrimary = false
     *   Student paired to this slot → Role = "Student"
     *
     * Other students don't appear on this Opp — every Opp owns exactly one
     * student in its OCR list.
     */
    private static void syncOpportunityContactRolesPerOpp(List<Lead> leads,
                                                          Map<Id, Id> contactIdByLeadId,
                                                          Map<Id, FamilyExtras> familyByLead,
                                                          Map<Id, Map<Integer, Id>> oppIdBySlotByLead) {
        Set<Id> oppIds = new Set<Id>();
        for (Map<Integer, Id> bySlot : oppIdBySlotByLead.values()) {
            for (Id oppId : bySlot.values()) if (oppId != null) oppIds.add(oppId);
        }
        if (oppIds.isEmpty()) return;

        Map<Id, Map<Id, OpportunityContactRole>> existingByOppByContact = new Map<Id, Map<Id, OpportunityContactRole>>();
        for (OpportunityContactRole ocr : [
            SELECT Id, OpportunityId, ContactId, Role, IsPrimary
            FROM OpportunityContactRole
            WHERE OpportunityId IN :oppIds
        ]) {
            Map<Id, OpportunityContactRole> byContact = existingByOppByContact.get(ocr.OpportunityId);
            if (byContact == null) {
                byContact = new Map<Id, OpportunityContactRole>();
                existingByOppByContact.put(ocr.OpportunityId, byContact);
            }
            byContact.put(ocr.ContactId, ocr);
        }

        List<OpportunityContactRole> toInsert = new List<OpportunityContactRole>();
        List<OpportunityContactRole> toUpdate = new List<OpportunityContactRole>();

        for (Lead l : leads) {
            Map<Integer, Id> oppBySlot = oppIdBySlotByLead.get(l.Id);
            if (oppBySlot == null || oppBySlot.isEmpty()) continue;
            FamilyExtras fe = familyByLead.get(l.Id);
            Id primaryContactId = contactIdByLeadId.get(l.Id);

            for (Integer slot : oppBySlot.keySet()) {
                Id oppId = oppBySlot.get(slot);
                if (oppId == null) continue;
                Map<Id, OpportunityContactRole> existing = existingByOppByContact.get(oppId);
                if (existing == null) existing = new Map<Id, OpportunityContactRole>();

                if (primaryContactId != null) {
                    upsertOcr(toInsert, toUpdate, existing, oppId, primaryContactId, OCR_ROLE_PARENT, true);
                }
                if (fe != null && fe.parent2ContactId != null) {
                    upsertOcr(toInsert, toUpdate, existing, oppId, fe.parent2ContactId, OCR_ROLE_PARENT, false);
                }
                if (fe != null && slot != null) {
                    Id studentContactId = fe.studentContactIdBySlot.get(slot);
                    if (studentContactId != null) {
                        upsertOcr(toInsert, toUpdate, existing, oppId, studentContactId, OCR_ROLE_STUDENT, false);
                    }
                }
            }
        }

        if (!toInsert.isEmpty()) {
            Database.SaveResult[] r = Database.insert(toInsert, false);
            logSaveErrors('OCR insert', r);
        }
        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] r = Database.update(toUpdate, false);
            logSaveErrors('OCR update', r);
        }
    }

    private static void upsertOcr(List<OpportunityContactRole> toInsert,
                                  List<OpportunityContactRole> toUpdate,
                                  Map<Id, OpportunityContactRole> existingByContact,
                                  Id oppId,
                                  Id contactId,
                                  String desiredRole,
                                  Boolean desiredPrimary) {
        OpportunityContactRole existing = existingByContact.get(contactId);
        if (existing == null) {
            toInsert.add(new OpportunityContactRole(
                OpportunityId = oppId,
                ContactId     = contactId,
                Role          = desiredRole,
                IsPrimary     = desiredPrimary
            ));
            return;
        }
        Boolean changed = false;
        if (existing.Role != desiredRole) {
            existing.Role = desiredRole;
            changed = true;
        }
        if (existing.IsPrimary != desiredPrimary) {
            existing.IsPrimary = desiredPrimary;
            changed = true;
        }
        if (changed) toUpdate.add(existing);
    }

    /**
     * For each Lead with N enrolling students, clone the primary Opportunity
     * (slot 1) once per additional student so the family ends up with one
     * Opportunity per enrolling student.
     *
     * Returns a per-Lead map: slot (1..N) → Opportunity Id. Slot 1 is the
     * Opp that LeadConvert (or the manual button) already created; slots 2
     * and 3 are the clones we insert here. The slot mirrors the Lead's
     * Student_Name__c / Student_2_Name__c / Student_3_Name__c position so
     * downstream rename + OCR steps know which student belongs to which Opp.
     *
     * Reused (deduped) Opps are returned as a single-entry slot-1 map and
     * never cloned — pre-existing Opps stay untouched.
     */
    private static Map<Id, Map<Integer, Id>> cloneOpportunitiesForAdditionalStudents(
            List<Lead> leads,
            Map<Id, Id> opportunityIdByLeadId,
            Map<Id, Id> matchedOppByLead,
            Map<Id, FamilyExtras> familyByLead) {
        Map<Id, Map<Integer, Id>> oppIdBySlotByLead = new Map<Id, Map<Integer, Id>>();
        Set<Id> primaryOppIdsToClone = new Set<Id>();
        Map<Id, List<Integer>> additionalSlotsByLead = new Map<Id, List<Integer>>();

        for (Lead l : leads) {
            Id primaryOppId = opportunityIdByLeadId.get(l.Id);
            if (primaryOppId == null) continue;

            Map<Integer, Id> slotMap = new Map<Integer, Id>();
            slotMap.put(1, primaryOppId);
            oppIdBySlotByLead.put(l.Id, slotMap);

            // Don't multiply pre-existing Opps that were reused via dedup.
            if (matchedOppByLead != null && matchedOppByLead.containsKey(l.Id)) continue;

            FamilyExtras fe = familyByLead.get(l.Id);
            if (fe == null || fe.studentContactIdBySlot.isEmpty()) continue;

            List<Integer> needs = new List<Integer>();
            for (Integer slot : fe.studentContactIdBySlot.keySet()) {
                if (slot != null && slot > 1) needs.add(slot);
            }
            if (needs.isEmpty()) continue;
            needs.sort();
            primaryOppIdsToClone.add(primaryOppId);
            additionalSlotsByLead.put(l.Id, needs);
        }

        if (primaryOppIdsToClone.isEmpty()) return oppIdBySlotByLead;

        Map<Id, Opportunity> primaryById = new Map<Id, Opportunity>([
            SELECT Id, Name, AccountId, StageName, CloseDate, OwnerId, LeadSource,
                   Type, Description, Amount, Probability,
                   ForecastCategoryName, CampaignId
            FROM Opportunity WHERE Id IN :primaryOppIdsToClone
        ]);

        List<Opportunity> oppsToInsert = new List<Opportunity>();
        // Parallel arrays so we can map insert results back to (lead, slot).
        List<Id> insertLeadIds = new List<Id>();
        List<Integer> insertSlots = new List<Integer>();

        for (Lead l : leads) {
            List<Integer> needs = additionalSlotsByLead.get(l.Id);
            if (needs == null) continue;
            Opportunity orig = primaryById.get(opportunityIdByLeadId.get(l.Id));
            if (orig == null) continue;
            for (Integer slot : needs) {
                Opportunity clone = orig.clone(false, true, false, false);
                oppsToInsert.add(clone);
                insertLeadIds.add(l.Id);
                insertSlots.add(slot);
            }
        }
        if (oppsToInsert.isEmpty()) return oppIdBySlotByLead;

        Database.SaveResult[] results = Database.insert(oppsToInsert, false);
        logSaveErrors('Opportunity clone insert', results);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) continue;
            Map<Integer, Id> slotMap = oppIdBySlotByLead.get(insertLeadIds[i]);
            if (slotMap != null) slotMap.put(insertSlots[i], results[i].getId());
        }
        return oppIdBySlotByLead;
    }

    /**
     * Stamp StageName = "Ready to Schedule SOM" on every freshly-created
     * per-slot Opportunity so each new Opp lands in the right stage.
     *
     * Slot-1 Opps reused via dedup (matchedOppByLead) are skipped so we
     * don't disturb pre-existing Opportunities.
     *
     * The Opportunity Name itself is set by the
     * "Opportunity Name From Student OCR" flow when the Student
     * OpportunityContactRole is inserted by syncOpportunityContactRolesPerOpp.
     */
    private static void setOpportunityStagePerSlot(List<Lead> leads,
                                                   Map<Id, Map<Integer, Id>> oppIdBySlotByLead,
                                                   Map<Id, Id> matchedOppByLead) {
        if (oppIdBySlotByLead == null || oppIdBySlotByLead.isEmpty()) return;

        List<Opportunity> oppUpdates = new List<Opportunity>();
        for (Lead l : leads) {
            Map<Integer, Id> slotMap = oppIdBySlotByLead.get(l.Id);
            if (slotMap == null) continue;
            Boolean primaryReused = (matchedOppByLead != null && matchedOppByLead.containsKey(l.Id));

            for (Integer slot : slotMap.keySet()) {
                Id oppId = slotMap.get(slot);
                if (oppId == null) continue;
                if (slot == 1 && primaryReused) continue;
                oppUpdates.add(new Opportunity(Id = oppId, StageName = OPPORTUNITY_STAGE));
            }
        }
        if (oppUpdates.isEmpty()) return;

        Database.SaveResult[] r = Database.update(oppUpdates, false);
        logSaveErrors('Opportunity stage', r);
    }

    private static void applyAllowDuplicateOptions(List<SObject> records) {
        Database.DMLOptions opt = new Database.DMLOptions();
        opt.DuplicateRuleHeader.AllowSave = true;
        for (SObject r : records) r.setOptions(opt);
    }

    private static void logSaveErrors(String label, Database.SaveResult[] results) {
        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult r = results[i];
            if (!r.isSuccess()) {
                for (Database.Error err : r.getErrors()) {
                    System.debug(LoggingLevel.WARN,
                        'LeadAutoConvert ' + label + ' [row ' + i + '] FAILED: ' +
                        err.getStatusCode() + ' — ' + err.getMessage());
                }
            }
        }
    }

    // ─── Builders ──────────────────────────────────────────────────
    private static Contact buildPrimaryContactUpdate(Id contactId, Lead l, Map<String, Id> rtMap) {
        Contact c = new Contact(Id = contactId);
        Id parentRtId = lookupRecordTypeId(rtMap, CONTACT_RT_PARENT);
        if (parentRtId != null) c.RecordTypeId = parentRtId;

        // Prefer explicit Parent_1_* fields, fall back to whatever LeadConvert
        // populated from Lead.FirstName / LastName / Email / Phone.
        if (String.isNotBlank(l.Parent_1_Name_First_Last__c)) {
            String[] parts = splitName(l.Parent_1_Name_First_Last__c);
            if (parts[0] != null) c.FirstName = parts[0];
            if (parts[1] != null) c.LastName  = parts[1];
        }
        if (String.isNotBlank(l.Parent_1_Email__c)) c.Email = l.Parent_1_Email__c;
        if (String.isNotBlank(l.Parent_1_Phone__c)) c.Phone = l.Parent_1_Phone__c;
        if (String.isNotBlank(l.Parent_1_ID__c))    c.Parent_ID__c = l.Parent_1_ID__c;
        return c;
    }

    private static Contact buildParent2Contact(Id accountId, Lead l, Map<String, Id> rtMap) {
        String[] parts = splitName(l.Parent_2_Name_First_Last__c);
        Contact c = new Contact(
            AccountId = accountId,
            FirstName = parts[0],
            LastName  = String.isNotBlank(parts[1]) ? parts[1] : 'Parent',
            Email     = l.Parent_2_Email__c,
            Phone     = l.Parent_2_Phone__c
        );
        Id parentRtId = lookupRecordTypeId(rtMap, CONTACT_RT_PARENT);
        if (parentRtId != null) c.RecordTypeId = parentRtId;
        if (String.isNotBlank(l.Parent_2_ID__c)) c.Parent_ID__c = l.Parent_2_ID__c;
        return c;
    }

    private static Contact buildStudentContact(Id accountId, Lead l, Integer slot, Map<String, Id> rtMap) {
        String fullName = getStudentNameForSlot(l, slot);
        String email    = getStudentEmailForSlot(l, slot);
        String[] parts  = splitName(fullName);
        Contact c = new Contact(
            AccountId = accountId,
            FirstName = parts[0],
            LastName  = String.isNotBlank(parts[1]) ? parts[1] : 'Student',
            Email     = email
        );
        Id studentRtId = lookupRecordTypeId(rtMap, CONTACT_RT_STUDENT);
        if (studentRtId != null) c.RecordTypeId = studentRtId;
        String studentId = getStudentIdForSlot(l, slot);
        if (String.isNotBlank(studentId)) c.Student_ID__c = studentId;
        return c;
    }

    private static String getStudentIdForSlot(Lead l, Integer slot) {
        if (slot == null) return null;
        if (slot == 1) return l.Student_ID_1__c;
        if (slot == 2) return l.Student_ID_2__c;
        if (slot == 3) return l.Student_ID_3__c;
        return null;
    }

    private static String getStudentNameForSlot(Lead l, Integer slot) {
        if (slot == null) return null;
        if (slot == 1) return l.Student_Name__c;
        if (slot == 2) return l.Student_2_Name__c;
        if (slot == 3) return l.Student_3_Name__c;
        return null;
    }

    private static String getStudentEmailForSlot(Lead l, Integer slot) {
        if (slot == null) return null;
        if (slot == 1) return l.Student_Email__c;
        if (slot == 2) return l.Student_2_Email__c;
        if (slot == 3) return l.Student_3_Email__c;
        return null;
    }

    // ─── Helpers ───────────────────────────────────────────────────
    private static Map<String, Id> getContactRecordTypeMap() {
        // Index by Name AND DeveloperName, both as-is and lowercased, so the
        // lookup matches whether the org's record type is "Parent" /
        // "parent" / "Parent_Contact" etc. — without forcing the admin to
        // rename it.
        Map<String, Id> result = new Map<String, Id>();
        for (RecordType rt : [
            SELECT Id, Name, DeveloperName
            FROM RecordType
            WHERE SObjectType = 'Contact' AND IsActive = true
        ]) {
            if (String.isNotBlank(rt.DeveloperName)) {
                result.put(rt.DeveloperName, rt.Id);
                result.put(rt.DeveloperName.toLowerCase(), rt.Id);
            }
            if (String.isNotBlank(rt.Name)) {
                result.put(rt.Name, rt.Id);
                result.put(rt.Name.toLowerCase(), rt.Id);
            }
        }
        System.debug(LoggingLevel.INFO,
            'LeadAutoConvert: Contact RecordType keys available = ' + result.keySet());
        return result;
    }

    /** Forgiving record-type lookup: tries the literal key first, then
     *  lowercase, returns null if neither matches so the caller can fall
     *  back to the default record type rather than throwing. */
    private static Id lookupRecordTypeId(Map<String, Id> rtMap, String key) {
        if (rtMap == null || String.isBlank(key)) return null;
        Id id = rtMap.get(key);
        if (id != null) return id;
        return rtMap.get(key.toLowerCase());
    }

    private static Integer parseStudentCount(String picklistValue) {
        if (String.isBlank(picklistValue)) return 0;
        try {
            Integer n = Integer.valueOf(picklistValue.trim());
            if (n < 0) return 0;
            return Math.min(n, 3);
        } catch (Exception e) {
            return 0;
        }
    }

    private static String[] splitName(String full) {
        String[] result = new String[]{ null, null };
        if (String.isBlank(full)) return result;
        String trimmed = full.trim();
        Integer idx = trimmed.indexOf(' ');
        if (idx < 0) {
            result[1] = trimmed;
        } else {
            result[0] = trimmed.substring(0, idx);
            result[1] = trimmed.substring(idx + 1).trim();
        }
        return result;
    }
}
