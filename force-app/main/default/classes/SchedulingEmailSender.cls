public without sharing class SchedulingEmailSender {

    // ───────────────────────────────────────────────────────────────────────
    //  PRODUCTION: environment-specific values. Update these BEFORE the
    //  production deploy — every link emailed from prod must point at the
    //  production Experience Cloud Site URL, not the sandbox.
    //
    //  Same hardcoded URL also appears in:
    //    • LeadICScheduleTokenStamper.cls   (BOOKING_BASE_URL)
    //    • OpportunitySchedulingLinkGenerator.cls   (BOOKING_BASE_URL)
    //  Update all three together for production.
    //
    //  TODO (post-launch): move to a Custom Metadata Type
    //  (Scheduling_Config__mdt) so per-org promotion doesn't require an
    //  Apex deploy.
    // ───────────────────────────────────────────────────────────────────────
    private static final String BOOKING_BASE_URL =
        'https://site-enterprise-6958--dev2.sandbox.my.site.com/booking';

    // PRODUCTION: confirm the FSS shared inbox before deploy. CC'd on
    // every "Send FSS Scheduling Link" email so the FSS team has visibility.
    private static final String FSS_CC_ADDRESS = 'fss@zenithprepacademy.com';

    private static final String LINK_PLACEHOLDER = '[[SCHEDULING_LINK]]';

    private static final Map<String, String> TEMPLATE_MAP = new Map<String, String>{
        'PD'  => 'PD_Scheduling_Email',
        'FSS' => 'FSS_Scheduling_Email'
    };

    public class EmailRequest {
        @InvocableVariable(required=true label='Contact Id')
        public Id contactId;

        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='Email Type (PD or FSS)')
        public String emailType;

        @InvocableVariable(label='Skip Email (generate link only)')
        public Boolean skipEmail;
    }

    public class EmailResult {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String errorMessage;
    }

    @InvocableMethod(
        label='Send Scheduling Email'
        description='Sends a PD or FSS scheduling email using an Email Template with a dynamic booking link'
        category='Scheduling'
    )
    public static List<EmailResult> sendSchedulingEmail(List<EmailRequest> requests) {
        List<EmailResult> results = new List<EmailResult>();

        // ── 1. Bulk-collect IDs ──────────────────────────────────────────
        Set<Id> contactIds = new Set<Id>();
        Set<Id> oppIds     = new Set<Id>();
        Set<String> templateDevNames = new Set<String>();
        for (EmailRequest req : requests) {
            contactIds.add(req.contactId);
            oppIds.add(req.opportunityId);
            String bType = (req.emailType != null) ? req.emailType.toUpperCase() : 'PD';
            String devName = TEMPLATE_MAP.get(bType);
            if (devName != null) {
                templateDevNames.add(devName);
            }
        }

        // ── 2. Pre-query ALL shared data OUTSIDE the loop ────────────────
        Map<Id, Contact> contactMap = new Map<Id, Contact>([
            SELECT Id, FirstName, LastName, Name, Email
            FROM Contact WHERE Id IN :contactIds
        ]);
        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>([
            SELECT Id, Name, Account.Name, StageName,
                   PD_Scheduling_Link__c, FSS_Scheduling_Link__c
            FROM Opportunity WHERE Id IN :oppIds
        ]);

        // Pre-query ALL email templates at once (no SOQL in loop)
        Map<String, EmailTemplate> templateCache = new Map<String, EmailTemplate>();
        for (EmailTemplate et : [
            SELECT Id, DeveloperName, Subject, HtmlValue, Body
            FROM EmailTemplate
            WHERE DeveloperName IN :templateDevNames
        ]) {
            templateCache.put(et.DeveloperName, et);
        }

        // ── 3. Build emails and collect DML ──────────────────────────────
        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
        // Track Opp updates keyed by request index so we can selectively
        // null out a request's link stamp if its email fails. Map (rather
        // than parallel List) keeps index bookkeeping correct even when
        // skipEmail=true on some requests but not others — those entries
        // get an Opp update without an emailsToSend entry.
        Map<Integer, Opportunity> oppsByRequestIndex = new Map<Integer, Opportunity>();
        // Track which index maps to which request for result assembly
        List<Integer> emailToResultIndex = new List<Integer>();

        for (Integer i = 0; i < requests.size(); i++) {
            EmailRequest req = requests[i];
            EmailResult res = new EmailResult();
            Boolean skipEmail = (req.skipEmail != null && req.skipEmail);
            try {
                String bType = (req.emailType != null) ? req.emailType.toUpperCase() : 'PD';
                String templateDevName = TEMPLATE_MAP.get(bType);
                if (templateDevName == null) {
                    throw new AuraHandledException('Unknown email type: ' + req.emailType);
                }

                // Determine the booking link:
                //   - skipEmail=true  (Generate-Only): always mint a fresh
                //     token. The button's purpose is to issue/refresh the
                //     link, so callers expect a new value each click.
                //   - skipEmail=false (Send-Email): reuse the link already
                //     stamped on the Opportunity if populated. Don't churn
                //     tokens just because someone wants to re-send the
                //     email — the same link must keep working. Only mint
                //     a fresh token when the field is blank, so the email
                //     always carries a working URL.
                Opportunity oppRead = oppMap.get(req.opportunityId);
                String bookingLink = null;
                if (!skipEmail && oppRead != null) {
                    if (bType == 'PD' && String.isNotBlank(oppRead.PD_Scheduling_Link__c)) {
                        bookingLink = oppRead.PD_Scheduling_Link__c;
                    } else if (bType == 'FSS' && String.isNotBlank(oppRead.FSS_Scheduling_Link__c)) {
                        bookingLink = oppRead.FSS_Scheduling_Link__c;
                    }
                }
                if (String.isBlank(bookingLink)) {
                    String token = BookingTokenUtil.encrypt(req.contactId, req.opportunityId);
                    bookingLink = BOOKING_BASE_URL
                        + '?type=' + bType
                        + '&token=' + token;
                }

                if (!skipEmail) {
                    EmailTemplate tmpl = templateCache.get(templateDevName);
                    if (tmpl == null) {
                        throw new AuraHandledException(
                            'Email template "' + templateDevName + '" not found. '
                            + 'Please create it in Setup > Email Templates.');
                    }

                    Contact con = contactMap.get(req.contactId);
                    Opportunity opp = oppMap.get(req.opportunityId);

                    // Start from the raw template HTML and subject
                    String htmlBody  = tmpl.HtmlValue;
                    String subject   = tmpl.Subject;
                    String plainBody = tmpl.Body;

                    // Replace merge fields
                    if (con != null) {
                        htmlBody  = replaceMerge(htmlBody, '{!Contact.FirstName}', con.FirstName);
                        htmlBody  = replaceMerge(htmlBody, '{!Contact.LastName}', con.LastName);
                        htmlBody  = replaceMerge(htmlBody, '{!Contact.Name}', con.Name);
                        subject   = replaceMerge(subject, '{!Contact.FirstName}', con.FirstName);
                        subject   = replaceMerge(subject, '{!Contact.LastName}', con.LastName);
                        subject   = replaceMerge(subject, '{!Contact.Name}', con.Name);
                        if (plainBody != null) {
                            plainBody = replaceMerge(plainBody, '{!Contact.FirstName}', con.FirstName);
                            plainBody = replaceMerge(plainBody, '{!Contact.LastName}', con.LastName);
                            plainBody = replaceMerge(plainBody, '{!Contact.Name}', con.Name);
                        }
                    }
                    if (opp != null) {
                        htmlBody = replaceMerge(htmlBody, '{!Opportunity.Name}', opp.Name);
                        subject  = replaceMerge(subject, '{!Opportunity.Name}', opp.Name);
                        if (opp.Account != null) {
                            htmlBody = replaceMerge(htmlBody, '{!Opportunity.Account.Name}', opp.Account.Name);
                        }
                    }

                    // Replace scheduling link placeholder
                    htmlBody = htmlBody.replace(LINK_PLACEHOLDER, bookingLink);
                    if (plainBody != null) {
                        plainBody = plainBody.replace(LINK_PLACEHOLDER, bookingLink);
                    }

                    // Build email message.
                    //   • setSaveAsActivity(true) lets the platform log
                    //     this email as a real EmailMessage record — that
                    //     is what shows on the Opportunity / Contact
                    //     activity timeline as an Email entry (the email
                    //     icon, not a Task icon). Enhanced-Email orgs use
                    //     EmailMessage; classic orgs fall back to Task.
                    //   • setWhatId(opportunityId) populates
                    //     EmailMessage.RelatedToId so the email is
                    //     related to the Opp, not just the Account.
                    //   • Section 4c below double-checks RelatedToId and
                    //     fixes it up if the platform didn't carry it
                    //     across (some orgs route the auto-relation to
                    //     the Account instead, hiding the email from the
                    //     Opp timeline).
                    Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                    mail.setTargetObjectId(req.contactId);
                    mail.setWhatId(req.opportunityId);
                    mail.setSubject(subject);
                    mail.setHtmlBody(htmlBody);
                    if (plainBody != null) {
                        mail.setPlainTextBody(plainBody);
                    }
                    mail.setSaveAsActivity(true);
                    mail.setUseSignature(false);

                    if (bType == 'FSS' && String.isNotBlank(FSS_CC_ADDRESS)) {
                        mail.setCcAddresses(new List<String>{ FSS_CC_ADDRESS });
                    }

                    emailsToSend.add(mail);
                    emailToResultIndex.add(i);
                }

                // Pre-build Opportunity link + stage update.
                //   - PD link sent → stamp PD_Scheduling_Link__c (the
                //     populated value also serves as the "email already
                //     sent" guard via the flow's Check_PD_Link_Sent
                //     decision) and flip StageName to "SOM Link Sent".
                //   - FSS link sent → stamp FSS_Scheduling_Link__c (same
                //     pattern: populated value is the duplicate-send guard
                //     via the flow's Check_FSS_Link_Sent decision).
                Opportunity oppUpd = new Opportunity(Id = req.opportunityId);
                if (bType == 'PD') {
                    oppUpd.PD_Scheduling_Link__c = bookingLink;
                    if (oppRead != null && oppRead.StageName != 'SOM Scheduled'
                        && oppRead.StageName != 'Closed Won'
                        && oppRead.StageName != 'Closed Lost') {
                        oppUpd.StageName = 'SOM Link Sent';
                    }
                } else if (bType == 'FSS') {
                    oppUpd.FSS_Scheduling_Link__c = bookingLink;
                }
                oppsByRequestIndex.put(i, oppUpd);

                res.success = true;

            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }

        // ── 4. Batch send all emails at once ─────────────────────────────
        // Capture the timestamp BEFORE sendEmail so we can later identify
        // the EmailMessage records the platform creates for these sends
        // (Section 4c uses CreatedDate >= sendStartTime to scope the
        // RelatedToId fix-up query).
        DateTime sendStartTime = DateTime.now();
        Map<Integer, Boolean> requestSucceeded = new Map<Integer, Boolean>();
        if (!emailsToSend.isEmpty()) {
            try {
                Messaging.SendEmailResult[] sendResults = Messaging.sendEmail(emailsToSend);
                for (Integer j = 0; j < sendResults.size(); j++) {
                    Integer resultIdx = emailToResultIndex[j];
                    if (sendResults[j].isSuccess()) {
                        requestSucceeded.put(resultIdx, true);
                    } else {
                        results[resultIdx].success = false;
                        String errMsg = '';
                        for (Messaging.SendEmailError err : sendResults[j].getErrors()) {
                            errMsg += err.getMessage() + ' ';
                        }
                        results[resultIdx].errorMessage = errMsg.trim();
                        // Drop this request's Opp link stamp so the next
                        // retry isn't blocked by the duplicate-send guard.
                        oppsByRequestIndex.remove(resultIdx);
                    }
                }
            } catch (Exception ex) {
                // If batch send fails entirely, mark all email results as failed
                for (Integer idx : emailToResultIndex) {
                    results[idx].success = false;
                    results[idx].errorMessage = 'Email send failed: ' + ex.getMessage();
                    oppsByRequestIndex.remove(idx);
                }
            }
        }

        // ── 4c. EmailMessage RelatedToId fix-up ──────────────────────────
        // setSaveAsActivity(true) + setWhatId(opportunityId) is supposed to
        // create an EmailMessage with RelatedToId = opportunityId so the
        // email lands on the Opportunity activity timeline. In some orgs
        // (Enhanced Email + an after-insert flow on EmailMessage, certain
        // Account-roll-up configs) the platform routes RelatedToId to
        // the Account or leaves it null, which hides the email from the
        // Opp timeline.
        //
        // To guarantee the email shows on the Opp timeline, query the
        // EmailMessage records this transaction just produced (matched by
        // CreatedDate window + current user + recipient address) and
        // re-stamp RelatedToId to the Opportunity when needed.
        //
        // This block runs AFTER sendEmail, so we never modify drafts or
        // unrelated emails. Best-effort: a query / update failure logs to
        // the debug log and never rolls back the actual email send.
        Map<String, Id> emailAddrToOppId = new Map<String, Id>();
        for (Integer idx : requestSucceeded.keySet()) {
            EmailRequest req = requests[idx];
            Contact con = contactMap.get(req.contactId);
            if (con != null && String.isNotBlank(con.Email) && req.opportunityId != null) {
                emailAddrToOppId.put(con.Email.toLowerCase(), req.opportunityId);
            }
        }
        if (!emailAddrToOppId.isEmpty()) {
            try {
                Id currentUserId = UserInfo.getUserId();
                List<EmailMessage> recents = [
                    SELECT Id, ToAddress, RelatedToId
                    FROM EmailMessage
                    WHERE CreatedDate >= :sendStartTime
                    AND CreatedById = :currentUserId
                    LIMIT 200
                ];
                List<EmailMessage> emToUpdate = new List<EmailMessage>();
                for (EmailMessage em : recents) {
                    if (em.ToAddress == null) continue;
                    Id targetOpp = emailAddrToOppId.get(em.ToAddress.toLowerCase());
                    if (targetOpp != null && em.RelatedToId != targetOpp) {
                        em.RelatedToId = targetOpp;
                        emToUpdate.add(em);
                    }
                }
                if (!emToUpdate.isEmpty()) {
                    logSaveErrors('EmailMessage RelatedToId fix-up',
                        Database.update(emToUpdate, false));
                }
            } catch (Exception emEx) {
                System.debug(LoggingLevel.WARN,
                    'EmailMessage RelatedToId fix-up failed: ' + emEx.getMessage());
            }
        }

        // ── 5. Batch update Opportunity links ────────────────────────────
        // Deduplicate by Opportunity Id BEFORE the DML — a single bulk
        // invocation can carry two requests for the same Opp (e.g. PD
        // link + FSS link), which would otherwise produce two
        // Opportunity records with the same Id in one update() call and
        // throw DUPLICATE_VALUE. Merge populated fields from later
        // requests over earlier ones (last-write-wins is fine: re-using
        // the same Opp's link is deterministic).
        if (!oppsByRequestIndex.isEmpty()) {
            Map<Id, Opportunity> mergedOpps = new Map<Id, Opportunity>();
            for (Opportunity src : oppsByRequestIndex.values()) {
                if (src == null || src.Id == null) continue;
                Opportunity dst = mergedOpps.get(src.Id);
                if (dst == null) {
                    mergedOpps.put(src.Id, src);
                    continue;
                }
                if (src.PD_Scheduling_Link__c  != null) dst.PD_Scheduling_Link__c  = src.PD_Scheduling_Link__c;
                if (src.FSS_Scheduling_Link__c != null) dst.FSS_Scheduling_Link__c = src.FSS_Scheduling_Link__c;
                if (src.StageName              != null) dst.StageName              = src.StageName;
            }
            try {
                logSaveErrors('Opportunity link update',
                    Database.update(mergedOpps.values(), false));
            } catch (Exception updEx) {
                System.debug(LoggingLevel.WARN,
                    'Opportunity link batch update failed: ' + updEx.getMessage());
            }
        }

        return results;
    }

    // Walks Database.SaveResult[] and logs each row-level failure to the
    // debug log at WARN. allOrNone=false on the DML calls above lets
    // partial successes persist; this helper makes the per-row failures
    // visible without aborting the whole batch.
    private static void logSaveErrors(String label, Database.SaveResult[] saveResults) {
        if (saveResults == null) return;
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult sr = saveResults[i];
            if (sr.isSuccess()) continue;
            for (Database.Error err : sr.getErrors()) {
                System.debug(LoggingLevel.WARN,
                    label + ' partial failure [row ' + i + '] '
                    + err.getStatusCode() + ': ' + err.getMessage()
                    + ' fields=' + err.getFields());
            }
        }
    }

    private static String replaceMerge(String source, String mergeField, String value) {
        if (source == null) return source;
        return source.replace(mergeField, (value != null) ? value : '');
    }
}
