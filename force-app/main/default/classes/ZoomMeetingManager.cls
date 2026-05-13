// Invocable Apex used by Flows to CREATE / UPDATE / CANCEL a Zoom meeting tied to a ServiceAppointment, with dynamic host resolution and .ics calendar invites.
public without sharing class ZoomMeetingManager {

    public static final String ACTION_CREATE = 'CREATE';
    public static final String ACTION_UPDATE = 'UPDATE';
    public static final String ACTION_CANCEL = 'CANCEL';

    public static final String STATUS_SUCCESS = 'SUCCESS';
    public static final String STATUS_ERROR   = 'ERROR';
    public static final String STATUS_SKIPPED = 'SKIPPED';

    private static final String NAMED_CREDENTIAL   = 'callout:Zoom_App';
    private static final String ORG_SENDER_ADDRESS = 'info@zenithprepacademy.com';
    private static final String ORG_SENDER_NAME    = 'Zenith Prep Academy';
    private static final String ICS_UID_DOMAIN     = '@zenithprepacademy.com';

    // Email template DeveloperNames — same source applies in sandbox + prod (Ids differ between orgs).
    // If a template is renamed in Setup, update the matching constant here.
    // These are FALLBACKS — the Flow can override RESCHEDULE / CANCEL templates via InputWrapper.emailTemplateDeveloperName.
    private static final String SCHEDULED_EMAIL_TEMPLATE_DEV_NAME    = 'Meeting_Schedule_Email_Template_1765244752004';
    private static final String IC_SCHEDULED_EMAIL_TEMPLATE_DEV_NAME = 'Initial_Consultation_Meeting_Scheduled';
    private static final String RESCHEDULED_EMAIL_TEMPLATE_DEV_NAME  = 'Meeting_Rescheduled_Send_Email';
    private static final String CANCELLED_EMAIL_TEMPLATE_DEV_NAME    = 'Meeting_Cancelled_Send_Email';

    private static Map<String, Id> templateIdByDevName;

    private static Map<String, Id> getTemplateIdMap() {
        if (templateIdByDevName != null) return templateIdByDevName;
        templateIdByDevName = new Map<String, Id>();
        Set<String> names = new Set<String>{
            SCHEDULED_EMAIL_TEMPLATE_DEV_NAME,
            IC_SCHEDULED_EMAIL_TEMPLATE_DEV_NAME,
            RESCHEDULED_EMAIL_TEMPLATE_DEV_NAME,
            CANCELLED_EMAIL_TEMPLATE_DEV_NAME
        };
        for (EmailTemplate et : [
            SELECT Id, DeveloperName FROM EmailTemplate
            WHERE DeveloperName IN :names
        ]) {
            templateIdByDevName.put(et.DeveloperName, et.Id);
        }
        return templateIdByDevName;
    }

    private static Id getScheduledEmailTemplateId()   { return getTemplateIdMap().get(SCHEDULED_EMAIL_TEMPLATE_DEV_NAME); }
    private static Id getIcScheduledEmailTemplateId() { return getTemplateIdMap().get(IC_SCHEDULED_EMAIL_TEMPLATE_DEV_NAME); }
    private static Id getRescheduledEmailTemplateId() { return getTemplateIdMap().get(RESCHEDULED_EMAIL_TEMPLATE_DEV_NAME); }
    private static Id getCancelledEmailTemplateId()   { return getTemplateIdMap().get(CANCELLED_EMAIL_TEMPLATE_DEV_NAME); }

    // Resolves a Flow-supplied template DeveloperName to its Id. Adds it to the cache on first sight.
    // Returns null if the name is blank or no matching template exists in the org.
    private static Id resolveOverrideTemplateId(String devName) {
        if (String.isBlank(devName)) {
            System.debug(LoggingLevel.INFO, '>>> ZMM resolveOverrideTemplateId: blank devName -> null');
            return null;
        }
        String trimmed = devName.trim();
        getTemplateIdMap(); // ensure cache initialised
        if (templateIdByDevName.containsKey(trimmed) && templateIdByDevName.get(trimmed) != null) {
            System.debug(LoggingLevel.INFO,
                '>>> ZMM resolveOverrideTemplateId: cache hit for "' + trimmed +
                '" -> ' + templateIdByDevName.get(trimmed));
            return templateIdByDevName.get(trimmed);
        }
        try {
            List<EmailTemplate> rows = [
                SELECT Id, DeveloperName FROM EmailTemplate
                WHERE DeveloperName = :trimmed
                LIMIT 1
            ];
            if (rows.isEmpty()) {
                System.debug(LoggingLevel.WARN,
                    '>>> ZMM resolveOverrideTemplateId: NO EmailTemplate found for DeveloperName="' + trimmed +
                    '" (case-sensitive). Falling back to class default.');
                templateIdByDevName.put(trimmed, null);
                return null;
            }
            templateIdByDevName.put(rows[0].DeveloperName, rows[0].Id);
            System.debug(LoggingLevel.INFO,
                '>>> ZMM resolveOverrideTemplateId: SOQL hit for "' + trimmed +
                '" -> ' + rows[0].Id);
            return rows[0].Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '>>> ZMM resolveOverrideTemplateId: exception for "' + trimmed +
                '" -> ' + e.getMessage());
            return null;
        }
    }

    private static final String ROLE_ES  = 'ES';
    private static final String ROLE_AC  = 'AC';
    private static final String ROLE_PD  = 'PD';
    private static final String ROLE_FSS = 'FSS';

    public class InputWrapper {
        @InvocableVariable(required=true label='Service Appointment Id')
        public Id serviceAppointmentId;

        @InvocableVariable(
            required=false
            label='Action'
            description='CREATE (default) | UPDATE (reschedule) | CANCEL')
        public String action;

        @InvocableVariable(
            required=false
            label='Email Template Developer Name'
            description='Optional. DeveloperName of the Lightning email template to use for RESCHEDULE or CANCEL. If blank, falls back to the class constant. Ignored for CREATE (uses Contact vs Lead routing).')
        public String emailTemplateDeveloperName;

        @InvocableVariable(
            required=false
            label='Skip Customer Email'
            description='When true, manage() still creates/updates/cancels the Zoom meeting and stamps the SA, but does NOT send the customer-facing scheduled/rescheduled/cancelled email. Set to true from the Event-triggered Create-Zoom flow so Meeting_After_RTF can be the single sender of the Lightning-template scheduled email.')
        public Boolean skipCustomerEmail;
    }

    public class OutputWrapper {
        @InvocableVariable public String status;
        @InvocableVariable public String errorMessage;
        @InvocableVariable public String action;

        @InvocableVariable public String meetingUrl;
        @InvocableVariable public String joinUrl;
        @InvocableVariable public String startUrl;
        @InvocableVariable public String meetingId;
        @InvocableVariable public String hostEmail;

        @InvocableVariable public String  icsUid;
        @InvocableVariable public Integer icsSequence;
        @InvocableVariable public Boolean icsInviteSent;

        @InvocableVariable public String resolvedHostSource;
        @InvocableVariable public String resolvedRole;
    }

    // Invocable entry point — dispatches CREATE / UPDATE / CANCEL across the input batch and bulk-sends collected emails.
    @InvocableMethod(
        label='Manage Zoom Meeting + Calendar Invite'
        description='Create / Reschedule / Cancel a Zoom meeting. Host is resolved dynamically from the SA role fields (Educational Strategist, Admission Counselor, Program Director, Family Success Specialist), with Owner as fallback.'
        callout=true)
    public static List<OutputWrapper> manage(List<InputWrapper> inputs) {

        List<OutputWrapper> outputs = new List<OutputWrapper>();
        if (inputs == null || inputs.isEmpty()) return outputs;

        // Log every incoming row so we can see exactly what Flow is sending.
        for (Integer i = 0; i < inputs.size(); i++) {
            InputWrapper ip = inputs[i];
            System.debug(LoggingLevel.INFO,
                '>>> ZMM manage IN[' + i + ']: saId=' + (ip == null ? null : ip.serviceAppointmentId) +
                ' action=' + (ip == null ? null : ip.action) +
                ' emailTemplateDeveloperName=' + (ip == null ? null : ip.emailTemplateDeveloperName));
        }

        Set<Id> saIds = new Set<Id>();
        for (InputWrapper ip : inputs) {
            if (ip != null && ip.serviceAppointmentId != null) saIds.add(ip.serviceAppointmentId);
        }
        if (saIds.isEmpty()) return outputs;

        // Pre-warm the template cache with any Flow-supplied DeveloperNames so resolveOverrideTemplateId is free per-row.
        Set<String> flowSuppliedNames = new Set<String>();
        for (InputWrapper ip : inputs) {
            if (ip != null && String.isNotBlank(ip.emailTemplateDeveloperName)) {
                flowSuppliedNames.add(ip.emailTemplateDeveloperName.trim());
            }
        }
        if (!flowSuppliedNames.isEmpty()) {
            getTemplateIdMap(); // ensure cache initialised
            Set<String> missing = new Set<String>();
            for (String n : flowSuppliedNames) {
                if (!templateIdByDevName.containsKey(n)) missing.add(n);
            }
            if (!missing.isEmpty()) {
                for (EmailTemplate et : [
                    SELECT Id, DeveloperName FROM EmailTemplate
                    WHERE DeveloperName IN :missing
                ]) {
                    templateIdByDevName.put(et.DeveloperName, et.Id);
                }
                // Stamp nulls for any names that didn't resolve so we don't re-query per-row.
                for (String n : missing) {
                    if (!templateIdByDevName.containsKey(n)) {
                        templateIdByDevName.put(n, null);
                    }
                }
            }
            System.debug(LoggingLevel.INFO,
                '>>> ZMM manage: Flow-supplied names pre-warmed. Resolved map snapshot: ' + templateIdByDevName);
        }

        Map<Id, ServiceAppointment> saMap         = loadAppointments(saIds);
        Map<Id, Lead>               leadsById     = loadParentLeads(saMap.values());
        Map<Id, List<Contact>>      parentsByAcct = loadVerifiedParents(saMap.values());
        Map<Id, User>               ownerUsers    = loadOwnerUsers(saMap.values(), leadsById);
        Map<Id, User>               substitutes   = loadActiveSubstitutes(saMap.values());
        Id                          orgWideId     = lookupOrgWideEmailId(ORG_SENDER_ADDRESS);

        Http http = new Http();

        List<ZoomMeetingEmailService.SendInput> emailBatch = new List<ZoomMeetingEmailService.SendInput>();
        List<OutputWrapper> emailOwners = new List<OutputWrapper>();

        Map<Id, ServiceAppointment> sasToPersist = new Map<Id, ServiceAppointment>();

        for (InputWrapper ip : inputs) {
            OutputWrapper out = new OutputWrapper();
            out.action = (ip == null || String.isBlank(ip.action))
                         ? ACTION_CREATE : ip.action.toUpperCase();
            outputs.add(out);

            try {
                ServiceAppointment sa = saMap.get(ip.serviceAppointmentId);
                if (sa == null) {
                    out.status = STATUS_ERROR;
                    out.errorMessage = 'ServiceAppointment not found: ' + ip.serviceAppointmentId;
                    continue;
                }
                MeetingContext ctx = resolveContext(sa, leadsById, ownerUsers, substitutes);
                out.resolvedRole       = ctx.role;
                out.resolvedHostSource = ctx.hostSource;

                Id overrideTplId = resolveOverrideTemplateId(ip.emailTemplateDeveloperName);

                Boolean skipEmail = (ip.skipCustomerEmail == true);
                // When skipEmail is set, route this row's collected SendInputs into a throwaway batch
                // so dispatch() still performs Zoom CRUD + SA stamping but the customer email never
                // reaches deliverEmailBatch — Meeting_After_RTF becomes the single source of truth.
                List<ZoomMeetingEmailService.SendInput> rowBatch =
                    skipEmail ? new List<ZoomMeetingEmailService.SendInput>() : emailBatch;
                List<OutputWrapper> rowOwners =
                    skipEmail ? new List<OutputWrapper>() : emailOwners;

                System.debug(LoggingLevel.INFO,
                    '>>> ZMM manage ROW: SA=' + ip.serviceAppointmentId +
                    ' action=' + out.action +
                    ' flowTemplateName="' + ip.emailTemplateDeveloperName + '"' +
                    ' resolvedOverrideId=' + overrideTplId +
                    ' skipCustomerEmail=' + skipEmail);

                dispatch(out, sa, ctx, parentsByAcct, orgWideId, http,
                         rowBatch, rowOwners, sasToPersist, overrideTplId);

            } catch (Exception e) {
                out.status = STATUS_ERROR;
                out.errorMessage = 'Unhandled: ' + e.getMessage() + ' @ ' + e.getStackTraceString();
            }
        }

        if (!sasToPersist.isEmpty()) {
            update sasToPersist.values();
        }

        deliverEmailBatch(emailBatch, emailOwners);
        return outputs;
    }

    // Sends the booking-confirmation email + .ics for SAs whose Zoom meeting is already created and persisted.
    public static void sendInvitesForSavedAppointments(Set<Id> saIds) {
        if (saIds == null || saIds.isEmpty()) return;

        Map<Id, ServiceAppointment> saMap = loadAppointments(saIds);
        if (saMap.isEmpty()) return;

        Map<Id, Lead>           leadsById     = loadParentLeads(saMap.values());
        Map<Id, List<Contact>>  parentsByAcct = loadVerifiedParents(saMap.values());
        Map<Id, User>           ownerUsers    = loadOwnerUsers(saMap.values(), leadsById);
        Map<Id, User>           substitutes   = loadActiveSubstitutes(saMap.values());
        Id                      orgWideId     = lookupOrgWideEmailId(ORG_SENDER_ADDRESS);

        List<ZoomMeetingEmailService.SendInput> emailBatch = new List<ZoomMeetingEmailService.SendInput>();
        List<OutputWrapper>                     emailOwners = new List<OutputWrapper>();

        for (ServiceAppointment sa : saMap.values()) {
            String joinUrl = String.isNotBlank(sa.Zoom_Join_URL__c) ? sa.Zoom_Join_URL__c : sa.Zoom_Link__c;
            if (String.isBlank(joinUrl)) {
                System.debug(LoggingLevel.WARN,
                    'sendInvitesForSavedAppointments: skip SA ' + sa.Id +
                    ' — no Zoom join URL on Zoom_Join_URL__c or Zoom_Link__c');
                continue;
            }

            MeetingContext ctx = resolveContext(sa, leadsById, ownerUsers, substitutes);
            if (ctx == null || String.isBlank(ctx.attendeeEmail)) {
                System.debug(LoggingLevel.WARN,
                    'sendInvitesForSavedAppointments: skip SA ' + sa.Id +
                    ' — no attendee email (ContactId=' + sa.ContactId +
                    ', ParentRecordType=' + sa.ParentRecordType +
                    ', ParentRecordId=' + sa.ParentRecordId + ')');
                continue;
            }

            String uid = computeIcsUid(sa);
            Integer seq = deriveSequence(sa);

            OutputWrapper owner = new OutputWrapper();
            owner.action = ACTION_CREATE;
            owner.status = STATUS_SUCCESS;

            // Single family Lightning-template email — TO=customer, CC=verified parents +
            // booking guests + resolved host (lead owner). All recipients receive the same
            // template and the .ics. The host's Google Calendar is also populated by EAC syncing
            // the Salesforce Event built by ensureHostEvent — that path is independent of this .ics.
            //
            // ORGANIZER mailto is forced to ORG_SENDER_ADDRESS (info@zenithprepacademy.com) so
            // Gmail loads the calendar widget for every recipient including the host on CC. If
            // ORGANIZER matched the host's email, Gmail rejects the .ics with "Unable to load
            // event" for the host (their own email == ORGANIZER == recipient on CC). The host's
            // display name still rides in CN= via ctx.host, so calendar widgets show the host's
            // real name as the organizer regardless of the mailto value.
            String familyIcs = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_REQUEST,
                                        joinUrl, sa.Zoom_Meeting_ID__c, null, parentsByAcct,
                                        ORG_SENDER_ADDRESS);
            emailBatch.add(buildFamilySendInput(sa, ctx, parentsByAcct, orgWideId, familyIcs));
            emailOwners.add(owner);
        }

        deliverEmailBatch(emailBatch, emailOwners);
    }

    // Builds the family-side SendInput (TO=student, CC=verified parents + counselor + booking guests).
    private static ZoomMeetingEmailService.SendInput buildFamilySendInput(
        ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, String ics
    ) {
        ZoomMeetingEmailService.SendInput sin = new ZoomMeetingEmailService.SendInput();
        sin.inviteType    = ZoomMeetingEmailService.InviteType.NEW_BOOKING;
        sin.icsContent    = ics;
        sin.toEmail       = ctx.attendeeEmail;
        sin.ccEmails      = buildFamilyCcList(sa, ctx, parentsByAcct);
        sin.orgWideEmailId = orgWideId;
        sin.relatedWhatId  = sa.Id;
        sin.activityRelatedToId = sa.Opportunity__c;
        Id targetId = sa.ContactId != null
                      ? sa.ContactId
                      : ((sa.ParentRecordType == 'Lead') ? sa.ParentRecordId : null);
        sin.targetObjectId = targetId;
        sin.logEmailOnSend = (targetId != null);
        Boolean isLeadBased = sa.ContactId == null && sa.ParentRecordType == 'Lead';
        // Always populate the Apex-built subject + bodies so ZoomMeetingEmailService can use them
        // as a fallback when Messaging.renderStoredEmailTemplate throws — without falling back
        // we'd lose the ICS attachment (Salesforce drops setFileAttachments when setTemplateId fires).
        sin.subject   = buildSubject(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx);
        sin.htmlBody  = buildHtmlBody(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx, null);
        sin.plainBody = buildPlainBody(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx, null);
        if (targetId != null) {
            sin.templateId = isLeadBased
                ? getIcScheduledEmailTemplateId()
                : getScheduledEmailTemplateId();
        }
        return sin;
    }

    // CC list with only verified parents (host is added separately in buildFamilyCcList).
    private static List<String> parentsOnlyCcList(
        MeetingContext ctx, Map<Id, List<Contact>> parentsByAcct
    ) {
        List<String> out = new List<String>();
        if (ctx == null || ctx.accountIdForParents == null || parentsByAcct == null) return out;
        List<Contact> parents = parentsByAcct.get(ctx.accountIdForParents);
        if (parents == null) return out;
        for (Contact p : parents) {
            if (p != null && String.isNotBlank(p.Email)) out.add(p.Email);
        }
        return out;
    }

    // Family CC list = verified parents + booking guests + resolved host (lead owner).
    // Single Lightning-template email goes out to all of them. The host's Gmail calendar
    // widget may show "Unable to load event" since they're a recipient and the ORGANIZER,
    // but EAC syncs the Salesforce Event to the host's Google Calendar independently.
    private static List<String> buildFamilyCcList(
        ServiceAppointment sa, MeetingContext ctx, Map<Id, List<Contact>> parentsByAcct
    ) {
        List<String> out = new List<String>();
        out.addAll(parentsOnlyCcList(ctx, parentsByAcct));
        String guestStr = readGuestEmails(sa);
        if (String.isNotBlank(guestStr)) {
            for (String raw : guestStr.split(',')) {
                if (raw == null) continue;
                String trimmed = raw.trim();
                if (String.isNotBlank(trimmed)) out.add(trimmed);
            }
        }
        if (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Email)) {
            out.add(ctx.host.Email);
        }
        return out;
    }

    private static Boolean guestEmailsResolved = false;
    private static Boolean guestEmailsCache = false;
    // Schema-cached check for the optional Lead.Guest_Emails__c field.
    private static Boolean hasGuestEmailsField() {
        if (guestEmailsResolved) return guestEmailsCache;
        guestEmailsResolved = true;
        try {
            guestEmailsCache = Schema.SObjectType.Lead.fields
                .getMap().containsKey('guest_emails__c');
        } catch (Exception e) { guestEmailsCache = false; }
        return guestEmailsCache;
    }

    // Reads Guest_Emails__c off the SA's parent Lead via the Lead__r relationship.
    private static String readGuestEmails(ServiceAppointment sa) {
        if (sa == null || !hasGuestEmailsField()) return null;
        try {
            SObject leadRel = sa.getSObject('Lead__r');
            if (leadRel == null) return null;
            Object v = leadRel.get('Guest_Emails__c');
            return (v instanceof String) ? (String) v : null;
        } catch (Exception e) {
            return null;
        }
    }

    // Sends METHOD:CANCEL .ics emails for SAs whose meeting was cancelled, using a per-SA Lightning template.
    public static void sendCancellationsForSavedAppointments(Map<Id, Id> templateBySa) {
        if (templateBySa == null || templateBySa.isEmpty()) return;

        Map<Id, ServiceAppointment> saMap = loadAppointments(templateBySa.keySet());
        if (saMap.isEmpty()) return;

        Map<Id, Lead>           leadsById     = loadParentLeads(saMap.values());
        Map<Id, List<Contact>>  parentsByAcct = loadVerifiedParents(saMap.values());
        Map<Id, User>           ownerUsers    = loadOwnerUsers(saMap.values(), leadsById);
        Map<Id, User>           substitutes   = loadActiveSubstitutes(saMap.values());
        Id                      orgWideId     = lookupOrgWideEmailId(ORG_SENDER_ADDRESS);

        List<ZoomMeetingEmailService.SendInput> emailBatch = new List<ZoomMeetingEmailService.SendInput>();
        List<OutputWrapper>                     emailOwners = new List<OutputWrapper>();

        for (ServiceAppointment sa : saMap.values()) {
            Id templateId = templateBySa.get(sa.Id);
            if (templateId == null) continue;
            if (String.isBlank(sa.Zoom_Meeting_ID__c)) continue;
            String joinUrl = String.isNotBlank(sa.Zoom_Join_URL__c) ? sa.Zoom_Join_URL__c : sa.Zoom_Link__c;

            MeetingContext ctx = resolveContext(sa, leadsById, ownerUsers, substitutes);
            if (ctx == null || String.isBlank(ctx.attendeeEmail)) continue;

            String uid = computeIcsUid(sa);
            Integer seq = deriveSequence(sa);

            // ORG_SENDER_ADDRESS override on ORGANIZER — host is on CC of buildCcList, so the
            // cancellation widget would otherwise show "Unable to load event" for them.
            String ics = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_CANCEL,
                                  joinUrl, sa.Zoom_Meeting_ID__c, null, parentsByAcct,
                                  ORG_SENDER_ADDRESS);

            OutputWrapper owner = new OutputWrapper();
            owner.action = ACTION_CANCEL;
            owner.status = STATUS_SUCCESS;

            ZoomMeetingEmailService.SendInput sin = new ZoomMeetingEmailService.SendInput();
            sin.inviteType    = ZoomMeetingEmailService.InviteType.CANCELLATION;
            sin.icsContent    = ics;
            sin.toEmail       = ctx.attendeeEmail;
            sin.ccEmails      = buildCcList(sa, ctx, parentsByAcct);
            sin.orgWideEmailId = orgWideId;
            sin.relatedWhatId  = sa.Id;
            sin.activityRelatedToId = sa.Opportunity__c;
            sin.targetObjectId = sa.ContactId;
            sin.logEmailOnSend = (sa.ContactId != null);
            // Apex-built fallback for the renderStoredEmailTemplate catch path — keeps the
            // METHOD:CANCEL .ics attached so the customer's calendar removes the event.
            sin.subject   = buildSubject(ZoomMeetingEmailService.InviteType.CANCELLATION, sa, ctx);
            sin.htmlBody  = buildHtmlBody(ZoomMeetingEmailService.InviteType.CANCELLATION, sa, ctx, null);
            sin.plainBody = buildPlainBody(ZoomMeetingEmailService.InviteType.CANCELLATION, sa, ctx, null);
            if (sa.ContactId != null) {
                sin.templateId = templateId;
            }
            emailBatch.add(sin);
            emailOwners.add(owner);
        }

        deliverEmailBatch(emailBatch, emailOwners);
    }

    // Bulk-sends the collected email batch and folds each result back into its OutputWrapper.
    private static void deliverEmailBatch(
        List<ZoomMeetingEmailService.SendInput> batch,
        List<OutputWrapper> owners
    ) {
        if (batch == null || batch.isEmpty()) {
            System.debug(LoggingLevel.INFO,
                'deliverEmailBatch: empty batch, nothing to send');
            return;
        }
        System.debug(LoggingLevel.INFO,
            'deliverEmailBatch: dispatching ' + batch.size() + ' message(s)');
        // One-line summary of every send so you can see which templateId actually went out.
        for (Integer i = 0; i < batch.size(); i++) {
            ZoomMeetingEmailService.SendInput s = batch[i];
            System.debug(LoggingLevel.INFO,
                '>>> ZMM deliverEmailBatch[' + i + ']:' +
                ' to=' + s.toEmail +
                ' inviteType=' + s.inviteType +
                ' templateId=' + s.templateId +
                ' targetObjectId=' + s.targetObjectId +
                ' relatedWhatId=' + s.relatedWhatId +
                ' usingApexBody=' + (s.templateId == null));
        }
        List<ZoomMeetingEmailService.SendResult> results = ZoomMeetingEmailService.sendBulk(batch);
        for (Integer i = 0; i < results.size(); i++) {
            ZoomMeetingEmailService.SendResult r = results[i];
            OutputWrapper out = owners[i];
            out.icsInviteSent = r.success;
            if (r.success) {
                System.debug(LoggingLevel.INFO,
                    'deliverEmailBatch: msg ' + i + ' sent OK to ' + batch[i].toEmail);
            } else {
                System.debug(LoggingLevel.ERROR,
                    'deliverEmailBatch: msg ' + i + ' FAILED to ' + batch[i].toEmail +
                    ' — ' + r.errorMessage);
                if (String.isBlank(out.errorMessage)) {
                    out.errorMessage = 'Zoom action succeeded, but email failed: ' + r.errorMessage;
                }
            }
        }
    }

    // Routes an SA to the right CREATE / UPDATE / CANCEL handler based on out.action.
    private static void dispatch(
        OutputWrapper out, ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, Http http,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners,
        Map<Id, ServiceAppointment> sasToPersist,
        Id overrideTemplateId
    ) {
        switch on out.action {
            when 'CREATE' { handleCreate(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners, sasToPersist, overrideTemplateId, false); }
            when 'UPDATE' { handleUpdate(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners, sasToPersist, overrideTemplateId); }
            when 'CANCEL' { handleCancel(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners, overrideTemplateId); }
            when else {
                out.status = STATUS_ERROR;
                out.errorMessage = 'Unknown action: ' + out.action + '. Use CREATE | UPDATE | CANCEL.';
            }
        }
    }

    // CREATE handler: POST a new Zoom meeting, hydrate SA fields, queue email + persistence.
    // When the user's *intent* was UPDATE but we had to CREATE (no meetingId / Zoom 404),
    // `calledFromUpdate=true` makes the queued email be RESCHEDULE rather than NEW_BOOKING.
    private static void handleCreate(
        OutputWrapper out, ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, Http http,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners,
        Map<Id, ServiceAppointment> sasToPersist,
        Id overrideTemplateId,
        Boolean calledFromUpdate
    ) {
        if (!validateForCreate(out, sa, ctx)) return;

        Map<String, Object> payload = buildZoomPayload(sa, ctx);
        String endpoint = NAMED_CREDENTIAL + '/users/'
                        + EncodingUtil.urlEncode(ctx.host.Email.trim(), 'UTF-8')
                        + '/meetings';
        HttpResponse res = doCallout(http, 'POST', endpoint, payload);
        if (!isSuccess(res)) {
            out.status = STATUS_ERROR;
            out.errorMessage = 'Zoom create failed (host=' + ctx.host.Email + '): ' + describe(res);
            return;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        out.joinUrl    = (String) body.get('join_url');
        out.startUrl   = (String) body.get('start_url');
        out.meetingId  = body.containsKey('id') ? String.valueOf(body.get('id')) : null;
        out.meetingUrl = out.joinUrl;
        out.hostEmail  = ctx.host.Email;

        // Pure CREATE keeps the existing semantics where Zoom_* fields only get hydrated if blank.
        // The CREATE-via-UPDATE path *overwrites* them, because the previous Zoom meeting is gone.
        if (calledFromUpdate) {
            sa.Zoom_Join_URL__c  = out.joinUrl;
            sa.Zoom_Link__c      = out.joinUrl;
            sa.Zoom_Start_URL__c = out.startUrl;
            sa.Zoom_Meeting_ID__c = out.meetingId;
        } else {
            if (String.isBlank(sa.Zoom_Join_URL__c))  sa.Zoom_Join_URL__c  = out.joinUrl;
            if (String.isBlank(sa.Zoom_Link__c))      sa.Zoom_Link__c      = out.joinUrl;
            if (String.isBlank(sa.Zoom_Start_URL__c)) sa.Zoom_Start_URL__c = out.startUrl;
            if (String.isBlank(sa.Zoom_Meeting_ID__c)) sa.Zoom_Meeting_ID__c = out.meetingId;
        }
        if (sasToPersist != null) sasToPersist.put(sa.Id, sa);

        String uid = computeIcsUid(sa);
        Integer seq = calledFromUpdate ? deriveSequence(sa) : 0;
        out.icsUid      = uid;
        out.icsSequence = seq;

        // CREATE-via-UPDATE: send RESCHEDULE email so users see "rescheduled", not a fresh booking.
        if (calledFromUpdate
            && ctx != null && String.isNotBlank(ctx.attendeeEmail)) {
            String zoomInvitationText = fetchZoomInvitation(http, out.meetingId);
            // ORG_SENDER_ADDRESS override — see sendInvitesForSavedAppointments; host is on CC.
            String ics = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_REQUEST,
                                  out.joinUrl, out.meetingId, zoomInvitationText, parentsByAcct,
                                  ORG_SENDER_ADDRESS);
            queueInvite(ZoomMeetingEmailService.InviteType.RESCHEDULE,
                        sa, ctx, parentsByAcct, orgWideId, ics, zoomInvitationText,
                        out, emailBatch, emailOwners, overrideTemplateId);
            // Single email — host (lead owner) is included on CC via buildCcList inside
            // queueInvite, so they receive the same Lightning RESCHEDULE template the customer
            // gets. EAC syncs the updated SF Event to the host's Google Calendar separately.
            // Surface the fact that we had to recreate, so admins can see it in the OutputWrapper.
            out.action = ACTION_UPDATE;
        }

        // Host calendar coverage — guarantees an Event exists for the resolved host (creates if
        // missing, updates Owner / time / Zoom Location otherwise). Runs on both the pure-CREATE
        // path and the CREATE-via-UPDATE fallback so the organizer's calendar is always in sync.
        ensureHostEvent(sa, ctx);

        out.status = STATUS_SUCCESS;
    }

    // UPDATE handler: PATCH the existing Zoom meeting and queue a RESCHEDULE email;
    // if Zoom_Meeting_ID__c is missing or Zoom returns 404, falls back to creating a new
    // meeting AND still sends a RESCHEDULE email (handleCreate with calledFromUpdate=true).
    private static void handleUpdate(
        OutputWrapper out, ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, Http http,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners,
        Map<Id, ServiceAppointment> sasToPersist,
        Id overrideTemplateId
    ) {
        if (String.isBlank(sa.Zoom_Meeting_ID__c)) {
            System.debug(LoggingLevel.INFO,
                '>>> ZMM handleUpdate: SA ' + sa.Id +
                ' has no Zoom_Meeting_ID__c, falling back to CREATE-as-UPDATE (RESCHEDULE email).');
            handleCreate(out, sa, ctx, parentsByAcct, orgWideId, http,
                         emailBatch, emailOwners, sasToPersist, overrideTemplateId, true);
            return;
        }
        if (!validateForCreate(out, sa, ctx)) return;

        Map<String, Object> payload = buildZoomPayload(sa, ctx);
        String endpoint = NAMED_CREDENTIAL + '/meetings/' + sa.Zoom_Meeting_ID__c;
        HttpResponse res = doCallout(http, 'PATCH', endpoint, payload);

        if (res.getStatusCode() == 404) {
            System.debug(LoggingLevel.WARN,
                '>>> ZMM handleUpdate: Zoom PATCH 404 for meetingId=' + sa.Zoom_Meeting_ID__c +
                ' on SA ' + sa.Id + ', meeting no longer exists in Zoom. ' +
                'Falling back to CREATE-as-UPDATE (RESCHEDULE email).');
            // Clear the stale id so handleCreate writes the fresh one.
            sa.Zoom_Meeting_ID__c = null;
            handleCreate(out, sa, ctx, parentsByAcct, orgWideId, http,
                         emailBatch, emailOwners, sasToPersist, overrideTemplateId, true);
            return;
        }
        if (!isSuccess(res)) {
            out.status = STATUS_ERROR;
            out.errorMessage = 'Zoom update failed: ' + describe(res);
            return;
        }

        out.meetingId  = sa.Zoom_Meeting_ID__c;
        out.joinUrl    = sa.Zoom_Join_URL__c != null ? sa.Zoom_Join_URL__c : sa.Zoom_Link__c;
        out.startUrl   = sa.Zoom_Start_URL__c;
        out.meetingUrl = out.joinUrl;
        out.hostEmail  = ctx.host != null ? ctx.host.Email : null;

        String uid = computeIcsUid(sa);
        Integer seq = deriveSequence(sa);
        out.icsUid = uid;
        out.icsSequence = seq;

        String zoomInvitationText = fetchZoomInvitation(http, out.meetingId);

        // ORG_SENDER_ADDRESS override — see sendInvitesForSavedAppointments; host is on CC of
        // buildCcList, so without this override the RESCHEDULE widget shows "Unable to load event".
        String ics = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_REQUEST,
                              out.joinUrl, out.meetingId, zoomInvitationText, parentsByAcct,
                              ORG_SENDER_ADDRESS);
        queueInvite(ZoomMeetingEmailService.InviteType.RESCHEDULE,
                    sa, ctx, parentsByAcct, orgWideId, ics, zoomInvitationText,
                    out, emailBatch, emailOwners, overrideTemplateId);

        // Keep the host's calendar Event in sync with the new SA times — and create one if no
        // Event exists yet (Sync_service_appointment_to_calendar only fires on insert with
        // ContactId, so Lead-based or older SAs without an Event would otherwise miss this push).
        // EAC syncs the updated SF Event to the host's Google Calendar. Host email is delivered
        // via buildCcList (CC) on the customer's Lightning RESCHEDULE email.
        ensureHostEvent(sa, ctx);

        out.status = STATUS_SUCCESS;
    }

    // Idempotent: creates the host's Salesforce Event if no Event is linked to this SA yet,
    // otherwise updates the existing Event(s) so OwnerId / time / Zoom Location stay in sync
    // with the latest SA + resolved host. Best-effort — never bubbles up to fail the Zoom action.
    //
    // Why this exists: the family-side .ics in the customer email triggers Gmail's "Unable to
    // load event" when the recipient also equals the ORGANIZER (the host is on CC of that email).
    // Rather than splitting the send into two messages again, we make sure the host has a
    // Salesforce Event on their own calendar so they can see the meeting independent of the
    // .ics. Picks up the same Event for downstream Einstein Activity Capture / Lightning Sync.
    private static void ensureHostEvent(ServiceAppointment sa, MeetingContext ctx) {
        if (sa == null || sa.Id == null || ctx == null || ctx.host == null || ctx.host.Id == null) return;
        if (sa.SchedStartTime == null || sa.SchedEndTime == null) return;

        String joinUrl = String.isNotBlank(sa.Zoom_Join_URL__c) ? sa.Zoom_Join_URL__c : sa.Zoom_Link__c;
        Long durMs    = sa.SchedEndTime.getTime() - sa.SchedStartTime.getTime();
        Integer durMin = (Integer)(durMs / (1000L * 60L));

        try {
            List<Event> linked = [
                SELECT Id, OwnerId, StartDateTime, EndDateTime, Location, DurationInMinutes
                FROM Event WHERE Service_Appointment__c = :sa.Id
            ];

            if (linked.isEmpty()) {
                Event e = new Event();
                e.OwnerId        = ctx.host.Id;
                e.Subject        = String.isNotBlank(sa.Subject) ? sa.Subject : 'Zenith Meeting';
                e.StartDateTime  = sa.SchedStartTime;
                e.EndDateTime    = sa.SchedEndTime;
                if (durMin > 0)  e.DurationInMinutes = durMin;
                e.IsAllDayEvent  = false;
                e.ShowAs         = 'Busy';
                e.Type           = 'Meeting';
                if (String.isNotBlank(joinUrl)) e.Location = joinUrl;
                if (sa.ContactId != null) {
                    e.WhoId = sa.ContactId;
                } else if (sa.ParentRecordType == 'Lead' && sa.ParentRecordId != null) {
                    e.WhoId = sa.ParentRecordId;
                }
                if (sa.Opportunity__c != null) {
                    e.WhatId = sa.Opportunity__c;
                } else if (sa.ParentRecordType == 'Account' && sa.ParentRecordId != null) {
                    e.WhatId = sa.ParentRecordId;
                }
                try { e.put('Service_Appointment__c', sa.Id); } catch (Exception ignored) { }
                insert e;
                return;
            }

            List<Event> toUpdate = new List<Event>();
            for (Event e : linked) {
                Boolean dirty = false;
                if (e.OwnerId != ctx.host.Id)                { e.OwnerId = ctx.host.Id; dirty = true; }
                if (e.StartDateTime != sa.SchedStartTime)    { e.StartDateTime = sa.SchedStartTime; dirty = true; }
                if (e.EndDateTime != sa.SchedEndTime)        { e.EndDateTime   = sa.SchedEndTime;   dirty = true; }
                if (durMin > 0 && e.DurationInMinutes != durMin) { e.DurationInMinutes = durMin;   dirty = true; }
                if (String.isNotBlank(joinUrl) && joinUrl != e.Location) { e.Location = joinUrl; dirty = true; }
                if (dirty) toUpdate.add(e);
            }
            if (!toUpdate.isEmpty()) update toUpdate;
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN,
                'ensureHostEvent: failed for SA ' + sa.Id + ' — ' + ex.getMessage());
        }
    }

    // CANCEL handler:
    //   1. Flip the parent Lead's Status (best-effort, only for Lead-based SAs).
    //   2. Best-effort Zoom DELETE so the join URL stops working (skipped if no meetingId).
    //   3. ALWAYS queue the cancellation email when we have an attendee — independent of
    //      whether step 2 ran/succeeded. The user's intent is "send cancellation"; the
    //      Zoom side-effect is a nice-to-have.
    private static void handleCancel(
        OutputWrapper out, ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, Http http,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners,
        Id overrideTemplateId
    ) {
        flipLeadStatusToCanceled(sa);

        // Step 2 — Zoom DELETE (best-effort). 404 from Zoom is fine: the meeting is already gone.
        Boolean zoomDeleted = false;
        Boolean zoomDeleteFailed = false;
        String  zoomDeleteError = null;
        if (String.isNotBlank(sa.Zoom_Meeting_ID__c)) {
            try {
                String endpoint = NAMED_CREDENTIAL + '/meetings/' + sa.Zoom_Meeting_ID__c
                                + '?schedule_for_reminder=false&cancel_meeting_reminder=true';
                HttpResponse res = doCallout(http, 'DELETE', endpoint, null);
                if (isSuccess(res) || res.getStatusCode() == 404) {
                    zoomDeleted = true;
                    System.debug(LoggingLevel.INFO,
                        '>>> ZMM handleCancel: Zoom DELETE ok for SA ' + sa.Id +
                        ' meetingId=' + sa.Zoom_Meeting_ID__c +
                        ' (statusCode=' + res.getStatusCode() + ')');
                } else {
                    zoomDeleteFailed = true;
                    zoomDeleteError = describe(res);
                    System.debug(LoggingLevel.WARN,
                        '>>> ZMM handleCancel: Zoom DELETE FAILED for SA ' + sa.Id +
                        ' meetingId=' + sa.Zoom_Meeting_ID__c + ' — ' + zoomDeleteError +
                        '. Cancellation email will still be sent.');
                }
            } catch (Exception e) {
                zoomDeleteFailed = true;
                zoomDeleteError = e.getMessage();
                System.debug(LoggingLevel.WARN,
                    '>>> ZMM handleCancel: Zoom DELETE threw for SA ' + sa.Id + ': ' + zoomDeleteError +
                    '. Cancellation email will still be sent.');
            }
        } else {
            System.debug(LoggingLevel.INFO,
                '>>> ZMM handleCancel: no Zoom_Meeting_ID__c on SA ' + sa.Id +
                ' — skipping Zoom DELETE, still sending cancellation email.');
        }

        // Populate output fields so Flow / callers can see what happened.
        String joinUrlForIcs = (sa.Zoom_Join_URL__c != null) ? sa.Zoom_Join_URL__c : sa.Zoom_Link__c;
        String uid = computeIcsUid(sa);
        Integer seq = deriveSequence(sa);
        out.icsUid = uid;
        out.icsSequence = seq;
        out.meetingId  = sa.Zoom_Meeting_ID__c;
        out.joinUrl    = joinUrlForIcs;
        out.startUrl   = sa.Zoom_Start_URL__c;
        out.meetingUrl = joinUrlForIcs;
        out.hostEmail  = (ctx != null && ctx.host != null) ? ctx.host.Email : null;

        // Step 3 — Cancellation email. Always send when we have an attendee.
        if (ctx == null || String.isBlank(ctx.attendeeEmail)) {
            out.status = STATUS_ERROR;
            out.errorMessage = 'Cancellation: no attendee email could be resolved. '
                             + 'Populate Contact.Email (for converted leads) or Lead.Email / SA.Email.';
            System.debug(LoggingLevel.WARN,
                '>>> ZMM handleCancel: SA ' + sa.Id + ' — no attendee email, no cancellation email sent.');
            return;
        }

        System.debug(LoggingLevel.INFO,
            '>>> ZMM handleCancel: SA=' + sa.Id +
            ' attendee=' + ctx.attendeeEmail +
            ' overrideTemplateId=' + overrideTemplateId +
            ' zoomDeleted=' + zoomDeleted +
            ' zoomDeleteFailed=' + zoomDeleteFailed);

        // ORG_SENDER_ADDRESS override — see sendInvitesForSavedAppointments; host is on CC of
        // buildCcList, so without this override the cancel widget shows "Unable to load event".
        String ics = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_CANCEL,
                              joinUrlForIcs, sa.Zoom_Meeting_ID__c, null, parentsByAcct,
                              ORG_SENDER_ADDRESS);
        queueInvite(ZoomMeetingEmailService.InviteType.CANCELLATION,
                    sa, ctx, parentsByAcct, orgWideId, ics, null,
                    out, emailBatch, emailOwners, overrideTemplateId);

        // Host (lead owner) is on CC via buildCcList, so they receive the same Lightning
        // CANCELLATION template the customer gets, with the METHOD:CANCEL .ics attached.

        // Final status: SUCCESS if Zoom delete went OK or wasn't needed; otherwise still SUCCESS
        // for the email path but surface the Zoom failure in errorMessage for visibility.
        out.status = STATUS_SUCCESS;
        if (zoomDeleteFailed && String.isBlank(out.errorMessage)) {
            out.errorMessage = 'Cancellation email queued, but Zoom DELETE failed: ' + zoomDeleteError;
        }
    }

    public class MeetingContext {
        public String role;
        public User   host;
        public String hostSource;
        public String attendeeName;
        public String attendeeEmail;
        public Id     accountIdForParents;
        public Lead   parentLead;
    }

    // Builds a MeetingContext (role, host, attendee, parents) for a given SA.
    private static MeetingContext resolveContext(
        ServiceAppointment sa, Map<Id, Lead> leadsById, Map<Id, User> ownerUsers,
        Map<Id, User> substitutes
    ) {
        MeetingContext ctx = new MeetingContext();
        ctx.role = classifyMeetingRole(sa);

        if (sa.ParentRecordType == 'Lead' && sa.ParentRecordId != null) {
            ctx.parentLead = leadsById.get(sa.ParentRecordId);
        }

        if (sa.Contact != null && String.isNotBlank(sa.Contact.Email)) {
            ctx.attendeeEmail = sa.Contact.Email;
            ctx.attendeeName  = sa.Contact.Name;
            ctx.accountIdForParents = sa.Contact.AccountId;
        } else if (ctx.parentLead != null && String.isNotBlank(ctx.parentLead.Email)) {
            ctx.attendeeEmail = ctx.parentLead.Email;
            ctx.attendeeName  = ctx.parentLead.Name;
        }
        if (String.isBlank(ctx.attendeeEmail) && String.isNotBlank(sa.Email)) {
            ctx.attendeeEmail = sa.Email;
        }

        pickHost(ctx, sa, ownerUsers, substitutes);
        return ctx;
    }

    // Classifies the SA's meeting role (ES / AC / PD / FSS) from Meeting_Type__c + Subject.
    private static String classifyMeetingRole(ServiceAppointment sa) {
        String mt   = sa.Meeting_Type__c == null ? '' : sa.Meeting_Type__c.toLowerCase();
        String subj = sa.Subject == null         ? '' : sa.Subject.toLowerCase();
        String combined = mt + ' | ' + subj;

        if (combined.contains('fss') || combined.contains('family success') || combined.contains('onboarding')) {
            return ROLE_FSS;
        }
        if (combined.contains('program director')) return ROLE_PD;
        if (combined.contains('initial consultation') || combined.contains('initial call')
            || combined.contains('admission') || combined.contains(' ic ') || combined.startsWith('ic ')) {
            return ROLE_AC;
        }
        return ROLE_ES;
    }

    // Resolves ctx.host through the layered fallback chain (Substitute -> Lead Owner -> SA role -> Contact role -> Lead role -> any role -> SA Owner -> Lead Owner).
    private static void pickHost(
        MeetingContext ctx, ServiceAppointment sa,
        Map<Id, User> ownerUsers, Map<Id, User> substitutes
    ) {
        if (ctx.role == ROLE_ES && sa.ContactId != null
            && substitutes != null && substitutes.containsKey(sa.ContactId)
            && isUsable(substitutes.get(sa.ContactId))) {
            ctx.host = substitutes.get(sa.ContactId);
            ctx.hostSource = 'Substitute__c.Active';
            return;
        }

        Boolean isLeadSA = sa.ContactId == null
                        && sa.ParentRecordType == 'Lead'
                        && ctx.parentLead != null;
        if (isLeadSA && ctx.parentLead.OwnerId != null
            && ownerUsers.containsKey(ctx.parentLead.OwnerId)
            && isUsable(ownerUsers.get(ctx.parentLead.OwnerId))) {
            ctx.host = ownerUsers.get(ctx.parentLead.OwnerId);
            ctx.hostSource = 'Lead.Owner';
            return;
        }

        if (ctx.role == ROLE_ES && isUsable(sa.Educational_Strategist__r)) {
            ctx.host = sa.Educational_Strategist__r;  ctx.hostSource = 'SA.Educational_Strategist__c'; return;
        }
        if (ctx.role == ROLE_AC && isUsable(sa.Admission_Counselor__r)) {
            ctx.host = sa.Admission_Counselor__r;     ctx.hostSource = 'SA.Admission_Counselor__c';    return;
        }
        if (ctx.role == ROLE_PD && isUsable(sa.Program_Director__r)) {
            ctx.host = sa.Program_Director__r;        ctx.hostSource = 'SA.Program_Director__c';       return;
        }
        if (ctx.role == ROLE_FSS && isUsable(sa.Family_Success_Specialist__r)) {
            ctx.host = sa.Family_Success_Specialist__r; ctx.hostSource = 'SA.Family_Success_Specialist__c'; return;
        }

        if (sa.Contact != null) {
            if (ctx.role == ROLE_ES && isUsable(sa.Contact.Counselor__r)) {
                ctx.host = sa.Contact.Counselor__r;  ctx.hostSource = 'Contact.Counselor__c'; return;
            }
            if (ctx.role == ROLE_PD && isUsable(sa.Contact.Program_Director__r)) {
                ctx.host = sa.Contact.Program_Director__r; ctx.hostSource = 'Contact.Program_Director__c'; return;
            }
            if (ctx.role == ROLE_FSS && isUsable(sa.Contact.Family_Success_Specialist__r)) {
                ctx.host = sa.Contact.Family_Success_Specialist__r; ctx.hostSource = 'Contact.Family_Success_Specialist__c'; return;
            }
            if (ctx.role == ROLE_AC && isUsable(sa.Contact.IC_admissions_counselor__r)) {
                ctx.host = sa.Contact.IC_admissions_counselor__r; ctx.hostSource = 'Contact.IC_admissions_counselor__c'; return;
            }
        }

        if (ctx.parentLead != null) {
            if (ctx.role == ROLE_AC && isUsable(ctx.parentLead.Assigned_Admission_Counsellor__r)) {
                ctx.host = ctx.parentLead.Assigned_Admission_Counsellor__r;
                ctx.hostSource = 'Lead.Assigned_Admission_Counsellor__c'; return;
            }
            if (ctx.role == ROLE_PD && isUsable(ctx.parentLead.Assigned_PD__r)) {
                ctx.host = ctx.parentLead.Assigned_PD__r;
                ctx.hostSource = 'Lead.Assigned_PD__c'; return;
            }
        }

        User anyRoleUser = firstUsable(new List<User>{
            sa.Educational_Strategist__r,
            sa.Admission_Counselor__r,
            sa.Program_Director__r,
            sa.Family_Success_Specialist__r
        });
        if (anyRoleUser != null) { ctx.host = anyRoleUser; ctx.hostSource = 'SA.AnyRole'; return; }

        if (sa.OwnerId != null && ownerUsers.containsKey(sa.OwnerId)) {
            User owner = ownerUsers.get(sa.OwnerId);
            if (isUsable(owner)) { ctx.host = owner; ctx.hostSource = 'SA.Owner'; return; }
        }

        if (ctx.parentLead != null && ctx.parentLead.OwnerId != null
            && ownerUsers.containsKey(ctx.parentLead.OwnerId)) {
            User lo = ownerUsers.get(ctx.parentLead.OwnerId);
            if (isUsable(lo)) { ctx.host = lo; ctx.hostSource = 'Lead.Owner'; return; }
        }
    }

    // For Lead-parented SAs, flips the Lead's Status to "IC Canceled" and mints a fresh single-use IC rebook token.
    private static void flipLeadStatusToCanceled(ServiceAppointment sa) {
        if (sa == null || sa.ParentRecordType != 'Lead' || sa.ParentRecordId == null) return;
        try {
            Lead leadUpdate = new Lead(
                Id = sa.ParentRecordId,
                Status = 'IC Canceled'
            );
            tryPutOnLead(leadUpdate, 'IC_Reschedule_Token__c',
                RescheduleTokenService.generateToken());
            tryPutOnLead(leadUpdate, 'IC_Meeting_Rescheduled__c', false);
            update leadUpdate;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'flipLeadStatusToCanceled: could not set Lead.Status=IC Canceled for SA '
                + sa.Id + ' (Lead Id ' + sa.ParentRecordId + '): ' + e.getMessage());
        }
    }

    // Best-effort dynamic put on a Lead — swallows missing-field exceptions for forward-compat.
    private static void tryPutOnLead(Lead l, String fieldName, Object value) {
        try { l.put(fieldName, value); } catch (Exception ignored) { }
    }

    // Builds a display name from User.FirstName + LastName, falling back to .Name only when both are blank.
    private static String composeUserDisplayName(User u) {
        if (u == null) return '';
        String fn = (u.FirstName != null) ? u.FirstName.trim() : '';
        String ln = (u.LastName != null)  ? u.LastName.trim()  : '';
        String composed = (fn + ' ' + ln).trim();
        if (String.isNotBlank(composed)) return composed;
        return (u.Name != null) ? u.Name.trim() : '';
    }

    private static Boolean isUsable(User u) {
        return u != null && String.isNotBlank(u.Email);
    }

    private static User firstUsable(List<User> candidates) {
        for (User u : candidates) if (isUsable(u)) return u;
        return null;
    }

    // Builds the JSON payload for the Zoom meetings POST/PATCH (topic, agenda, start, duration, settings, invitees).
    private static Map<String, Object> buildZoomPayload(ServiceAppointment sa, MeetingContext ctx) {
        Long durationMinutes =
            (sa.SchedEndTime.getTime() - sa.SchedStartTime.getTime()) / 60000L;
        String startTime = sa.SchedStartTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss') + 'Z';

        String tz = (ctx.host != null && String.isNotBlank(ctx.host.TimeZoneSidKey))
                    ? ctx.host.TimeZoneSidKey
                    : UserInfo.getTimeZone().getID();

        String topic  = buildTopic(sa, ctx);
        String hostName = composeUserDisplayName(ctx.host);
        if (String.isBlank(hostName)) hostName = ORG_SENDER_NAME;
        String agenda = 'Meeting with ' + hostName;

        Map<String, Object> settings = new Map<String, Object>{
            'join_before_host'                => false,
            'waiting_room'                    => true,
            'mute_upon_entry'                 => true,
            'registrants_email_notification'  => false
        };

        List<Map<String, Object>> meetingInvitees = buildZoomMeetingInvitees(sa, ctx);
        if (!meetingInvitees.isEmpty()) {
            settings.put('meeting_invitees', meetingInvitees);
        }

        return new Map<String, Object>{
            'topic'      => topic,
            'type'       => 2,
            'agenda'     => agenda,
            'start_time' => startTime,
            'duration'   => durationMinutes,
            'timezone'   => tz,
            'settings'   => settings
        };
    }

    // Builds Zoom's settings.meeting_invitees array from the primary attendee + booking guests.
    private static List<Map<String, Object>> buildZoomMeetingInvitees(
        ServiceAppointment sa, MeetingContext ctx
    ) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        Set<String> seen = new Set<String>();

        if (ctx != null && String.isNotBlank(ctx.attendeeEmail)) {
            String norm = ctx.attendeeEmail.toLowerCase().trim();
            seen.add(norm);
            out.add(new Map<String, Object>{ 'email' => ctx.attendeeEmail });
        }

        String guestStr = readGuestEmails(sa);
        if (String.isNotBlank(guestStr)) {
            for (String raw : guestStr.split(',')) {
                if (raw == null) continue;
                String email = raw.trim();
                if (String.isBlank(email)) continue;
                String norm = email.toLowerCase();
                if (seen.contains(norm)) continue;
                seen.add(norm);
                out.add(new Map<String, Object>{ 'email' => email });
            }
        }
        return out;
    }

    // Builds the Zoom meeting topic (Subject when set, otherwise Meeting_Type With Attendee).
    private static String buildTopic(ServiceAppointment sa, MeetingContext ctx) {
        if (String.isNotBlank(sa.Subject)) return sa.Subject;
        String mt = String.isBlank(sa.Meeting_Type__c) ? 'Meeting' : sa.Meeting_Type__c;
        String who = String.isNotBlank(ctx.attendeeName) ? ctx.attendeeName : '';
        return mt + (String.isBlank(who) ? '' : ' With ' + who);
    }

    // Issues an authenticated Zoom HTTP call via Named Credential.
    private static HttpResponse doCallout(Http http, String method, String endpoint, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod(method);
        req.setHeader('Accept', 'application/json');
        if (body != null) {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(body));
        }
        req.setTimeout(60000);
        return http.send(req);
    }

    private static Boolean isSuccess(HttpResponse res) {
        Integer code = res.getStatusCode();
        return code >= 200 && code < 300;
    }

    private static String describe(HttpResponse res) {
        return res.getStatusCode() + ' ' + res.getStatus() + ' Body=' + res.getBody();
    }

    // Deletes the Zoom meetings for the given SAs so the join URL stops working (no email is sent here).
    public static void cancelZoomMeetingsForSAs(Set<Id> saIds) {
        if (saIds == null || saIds.isEmpty()) return;
        List<ServiceAppointment> sas = [
            SELECT Id, Zoom_Meeting_ID__c
            FROM ServiceAppointment
            WHERE Id IN :saIds
              AND Zoom_Meeting_ID__c != null
        ];
        if (sas.isEmpty()) return;

        Http http = new Http();
        for (ServiceAppointment sa : sas) {
            try {
                String endpoint = NAMED_CREDENTIAL + '/meetings/' + sa.Zoom_Meeting_ID__c
                    + '?schedule_for_reminder=false&cancel_meeting_reminder=true';
                HttpResponse res = doCallout(http, 'DELETE', endpoint, null);
                if (!isSuccess(res) && res.getStatusCode() != 404) {
                    System.debug(LoggingLevel.WARN,
                        'cancelZoomMeetingsForSAs: Zoom DELETE failed for SA '
                        + sa.Id + ' meetingId=' + sa.Zoom_Meeting_ID__c
                        + ' — ' + describe(res));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'cancelZoomMeetingsForSAs: error deleting Zoom meeting for SA '
                    + sa.Id + ': ' + e.getMessage());
            }
        }
    }

    // Queueable wrapper around cancelZoomMeetingsForSAs so callers can enqueue the Zoom DELETE after their DML commit.
    public class ZoomCancelQueueable implements Queueable, Database.AllowsCallouts {
        private Set<Id> serviceAppointmentIds;
        public ZoomCancelQueueable(Set<Id> saIds) {
            this.serviceAppointmentIds = saIds;
        }
        public void execute(QueueableContext ctx) {
            ZoomMeetingManager.cancelZoomMeetingsForSAs(serviceAppointmentIds);
        }
    }

    // Queueable wrapper around manage(action='UPDATE') so callers can enqueue the Zoom PATCH after committing the new SchedStartTime.
    public class ZoomRescheduleQueueable implements Queueable, Database.AllowsCallouts {
        private Id serviceAppointmentId;
        private String emailTemplateDeveloperName;
        public ZoomRescheduleQueueable(Id saId) {
            this(saId, null);
        }
        public ZoomRescheduleQueueable(Id saId, String emailTemplateDeveloperName) {
            this.serviceAppointmentId = saId;
            this.emailTemplateDeveloperName = emailTemplateDeveloperName;
        }
        public void execute(QueueableContext ctx) {
            if (serviceAppointmentId == null) return;
            InputWrapper input = new InputWrapper();
            input.serviceAppointmentId = serviceAppointmentId;
            input.action = ACTION_UPDATE;
            input.emailTemplateDeveloperName = emailTemplateDeveloperName;
            ZoomMeetingManager.manage(new List<InputWrapper>{ input });
        }
    }

    // Validates that a CREATE has a host email, scheduled times, and an attendee email.
    private static Boolean validateForCreate(OutputWrapper out, ServiceAppointment sa, MeetingContext ctx) {
        if (ctx.host == null || String.isBlank(ctx.host.Email)) {
            out.status = STATUS_ERROR;
            out.errorMessage =
                'Could not resolve a host user for this Service Appointment. '
                + 'Populate one of: SA.Educational_Strategist__c / Admission_Counselor__c / '
                + 'Program_Director__c / Family_Success_Specialist__c - OR ensure the SA '
                + 'Owner is a User with an Email (role: ' + ctx.role + ').';
            return false;
        }
        if (sa.SchedStartTime == null || sa.SchedEndTime == null) {
            out.status = STATUS_ERROR;
            out.errorMessage = 'SchedStartTime and SchedEndTime are required.';
            return false;
        }
        if (String.isBlank(ctx.attendeeEmail)) {
            out.status = STATUS_ERROR;
            out.errorMessage =
                'No attendee email could be resolved. Populate Contact.Email (for '
                + 'converted leads) or Lead.Email / SA.Email.';
            return false;
        }
        return true;
    }

    // GETs the human-readable Zoom invitation text for a given meeting id.
    private static String fetchZoomInvitation(Http http, String meetingId) {
        if (String.isBlank(meetingId)) return null;
        try {
            String endpoint = NAMED_CREDENTIAL + '/meetings/' + meetingId + '/invitation';
            HttpResponse res = doCallout(http, 'GET', endpoint, null);
            if (!isSuccess(res)) return null;
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return (String) body.get('invitation');
        } catch (Exception e) {
            return null;
        }
    }

    private static String buildIcs(
        ServiceAppointment sa, MeetingContext ctx,
        String uid, Integer sequence, String method,
        String joinUrl, String meetingIdForDescription, String zoomInvitationText,
        Map<Id, List<Contact>> parentsByAcct
    ) {
        return buildIcs(sa, ctx, uid, sequence, method, joinUrl,
                        meetingIdForDescription, zoomInvitationText,
                        parentsByAcct, null);
    }

    // Builds the .ics body, with optional ORGANIZER mailto override (used for the host's own copy).
    private static String buildIcs(
        ServiceAppointment sa, MeetingContext ctx,
        String uid, Integer sequence, String method,
        String joinUrl, String meetingIdForDescription, String zoomInvitationText,
        Map<Id, List<Contact>> parentsByAcct,
        String organizerEmailOverride
    ) {
        String studentName = (sa.Contact != null && String.isNotBlank(sa.Contact.Name))
                             ? sa.Contact.Name
                             : (String.isNotBlank(ctx.attendeeName) ? ctx.attendeeName : 'Student');
        String summary = studentName + ' - Zenith Meeting';

        String hostName = (ctx != null && ctx.host != null)
                          ? composeUserDisplayName(ctx.host) : '';
        if (String.isBlank(hostName)) hostName = ORG_SENDER_NAME;

        String descText;
        if (String.isNotBlank(zoomInvitationText)) {
            descText = zoomInvitationText;
        } else {
            descText =
                hostName + ' is inviting you to a scheduled Zoom meeting.\n'
                + 'Join Zoom Meeting\n'
                + (String.isBlank(joinUrl) ? '' : joinUrl + '\n')
                + (String.isBlank(meetingIdForDescription)
                   ? ''
                   : '\nMeeting ID: ' + formatMeetingId(meetingIdForDescription) + '\n');
        }

        ZoomIcsBuilder.IcsInput ici = new ZoomIcsBuilder.IcsInput();
        ici.uid            = uid;
        ici.sequence       = sequence;
        ici.method         = method;
        ici.summary        = summary;
        ici.description    = descText;
        ici.location       = joinUrl;
        ici.startTime      = sa.SchedStartTime;
        ici.endTime        = sa.SchedEndTime;
        ici.organizerName  = (ctx != null && ctx.host != null)
                             ? composeUserDisplayName(ctx.host) : '';
        if (String.isBlank(ici.organizerName)) ici.organizerName = ORG_SENDER_NAME;
        if (String.isNotBlank(organizerEmailOverride)) {
            ici.organizerEmail = organizerEmailOverride;
        } else {
            ici.organizerEmail = (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Email))
                                 ? ctx.host.Email : ORG_SENDER_ADDRESS;
        }
        if (!ici.organizerEmail.equalsIgnoreCase(ORG_SENDER_ADDRESS)) {
            ici.organizerSentByEmail = ORG_SENDER_ADDRESS;
        }

        ici.primaryAttendee = new ZoomIcsBuilder.Attendee(
            ctx.attendeeName, ctx.attendeeEmail, 'REQ-PARTICIPANT'
        );

        ici.ccAttendees = buildCcAttendees(sa, ctx, parentsByAcct);

        return ZoomIcsBuilder.build(ici);
    }

    // Builds the .ics ATTENDEE list mirroring the email CC list (verified parents + host as CHAIR + booking guests).
    private static List<ZoomIcsBuilder.Attendee> buildCcAttendees(
        ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct
    ) {
        List<ZoomIcsBuilder.Attendee> out = new List<ZoomIcsBuilder.Attendee>();
        Set<String> seen = new Set<String>();
        String studentEmailLower = (ctx != null && String.isNotBlank(ctx.attendeeEmail))
                                   ? ctx.attendeeEmail.toLowerCase().trim() : '';

        if (ctx != null && ctx.accountIdForParents != null && parentsByAcct != null) {
            List<Contact> parents = parentsByAcct.get(ctx.accountIdForParents);
            if (parents != null) {
                for (Contact p : parents) {
                    if (p == null || String.isBlank(p.Email)) continue;
                    String norm = p.Email.toLowerCase().trim();
                    if (norm == studentEmailLower || seen.contains(norm)) continue;
                    seen.add(norm);
                    out.add(new ZoomIcsBuilder.Attendee(
                        String.isNotBlank(p.Name) ? p.Name : p.Email,
                        p.Email, 'REQ-PARTICIPANT'
                    ));
                }
            }
        }

        if (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Email)) {
            String norm = ctx.host.Email.toLowerCase().trim();
            if (norm != studentEmailLower && !seen.contains(norm)) {
                seen.add(norm);
                String hostDisplayName = composeUserDisplayName(ctx.host);
                out.add(new ZoomIcsBuilder.Attendee(
                    String.isNotBlank(hostDisplayName) ? hostDisplayName : ctx.host.Email,
                    ctx.host.Email, 'CHAIR', 'ACCEPTED', false
                ));
            }
        }

        String guestStr = readGuestEmails(sa);
        if (String.isNotBlank(guestStr)) {
            for (String raw : guestStr.split(',')) {
                if (raw == null) continue;
                String email = raw.trim();
                if (String.isBlank(email)) continue;
                String norm = email.toLowerCase();
                if (norm == studentEmailLower || seen.contains(norm)) continue;
                seen.add(norm);
                out.add(new ZoomIcsBuilder.Attendee(
                    email, email, 'REQ-PARTICIPANT'
                ));
            }
        }
        return out;
    }

    // Builds a SendInput for this SA and adds it to the transaction-wide email batch.
    //
    // Template selection rules (per your Flow requirement):
    //   1. Flow-supplied overrideTemplateId wins, regardless of Contact vs Lead parent.
    //   2. If override is null, fall back to the per-inviteType class-constant default.
    //   3. If neither resolves to a real EmailTemplate Id, fall back to the Apex-built body.
    //
    // targetObjectId must be a Contact, Lead, or User. For Lead-parented SAs we use the
    // parent Lead's Id so Lightning templates have a valid recipient for merge fields.
    private static void queueInvite(
        ZoomMeetingEmailService.InviteType inviteType,
        ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct,
        Id orgWideId, String ics, String zoomInvitationText,
        OutputWrapper out,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners,
        Id overrideTemplateId
    ) {
        // Resolve a valid targetObjectId — Contact for converted SAs, Lead for IC SAs, else null.
        Id targetId = sa.ContactId;
        if (targetId == null && sa.ParentRecordType == 'Lead' && sa.ParentRecordId != null) {
            targetId = sa.ParentRecordId;
        }

        ZoomMeetingEmailService.SendInput sin = new ZoomMeetingEmailService.SendInput();
        sin.inviteType = inviteType;
        sin.icsContent = ics;
        sin.toEmail    = ctx.attendeeEmail;
        sin.ccEmails   = buildCcList(sa, ctx, parentsByAcct);
        sin.orgWideEmailId = orgWideId;
        sin.relatedWhatId  = sa.Id;
        sin.activityRelatedToId = sa.Opportunity__c;
        sin.targetObjectId = targetId;
        sin.logEmailOnSend = (targetId != null);

        // Pick the template Id we want to use for this invite.
        Id resolvedTemplateId = null;
        String templateSource;
        if (overrideTemplateId != null) {
            resolvedTemplateId = overrideTemplateId;
            templateSource = 'flow-override';
        } else if (inviteType == ZoomMeetingEmailService.InviteType.NEW_BOOKING) {
            // CREATE keeps Contact-vs-Lead routing to the existing class defaults.
            Boolean isLeadBased = sa.ContactId == null && sa.ParentRecordType == 'Lead';
            resolvedTemplateId = isLeadBased
                ? getIcScheduledEmailTemplateId()
                : getScheduledEmailTemplateId();
            templateSource = 'create-default';
        } else if (inviteType == ZoomMeetingEmailService.InviteType.RESCHEDULE) {
            resolvedTemplateId = getRescheduledEmailTemplateId();
            templateSource = 'reschedule-default';
        } else if (inviteType == ZoomMeetingEmailService.InviteType.CANCELLATION) {
            resolvedTemplateId = getCancelledEmailTemplateId();
            templateSource = 'cancel-default';
        } else {
            templateSource = 'apex-body';
        }

        // Lightning templates require targetObjectId. If we don't have one, we cannot
        // use a template — fall through to the Apex-built body even if a template Id resolved.
        Boolean canUseTemplate = resolvedTemplateId != null && targetId != null;

        System.debug(LoggingLevel.INFO,
            '>>> ZMM queueInvite: SA=' + sa.Id +
            ' inviteType=' + inviteType +
            ' contactId=' + sa.ContactId +
            ' targetObjectId=' + targetId +
            ' overrideIn=' + overrideTemplateId +
            ' resolvedTemplateId=' + resolvedTemplateId +
            ' canUseTemplate=' + canUseTemplate +
            ' source=' + (canUseTemplate ? templateSource : 'apex-body'));

        // Always populate the Apex-built subject + bodies so ZoomMeetingEmailService can use them
        // as a fallback when Messaging.renderStoredEmailTemplate throws — without it Salesforce
        // would drop the .ics attachment (setFileAttachments is silently ignored after setTemplateId).
        sin.subject   = buildSubject(inviteType, sa, ctx);
        sin.htmlBody  = buildHtmlBody(inviteType, sa, ctx, zoomInvitationText);
        sin.plainBody = buildPlainBody(inviteType, sa, ctx, zoomInvitationText);
        if (canUseTemplate) {
            sin.templateId = resolvedTemplateId;
        }

        emailBatch.add(sin);
        emailOwners.add(out);
    }

    // CC list for create / reschedule / cancellation = verified parents + resolved host.
    // Single Lightning-template email goes to everyone, including the lead owner / host on CC.
    private static List<String> buildCcList(
        ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct
    ) {
        List<String> cc = new List<String>();

        if (ctx != null && ctx.accountIdForParents != null) {
            List<Contact> parents = parentsByAcct.get(ctx.accountIdForParents);
            if (parents != null) {
                for (Contact p : parents) if (String.isNotBlank(p.Email)) cc.add(p.Email);
            }
        }

        if (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Email)) {
            cc.add(ctx.host.Email);
        }

        return cc;
    }

    private static String studentFullName(ServiceAppointment sa, MeetingContext ctx) {
        if (sa.Contact != null && String.isNotBlank(sa.Contact.Name)) return sa.Contact.Name;
        if (ctx != null && String.isNotBlank(ctx.attendeeName))       return ctx.attendeeName;
        return 'Student';
    }

    private static String studentFirstName(ServiceAppointment sa, MeetingContext ctx) {
        String full = studentFullName(sa, ctx);
        return full.contains(' ') ? full.substringBefore(' ') : full;
    }

    private static String scheduledDateLabel(ServiceAppointment sa, MeetingContext ctx) {
        if (sa.SchedStartTime == null) return '';
        return sa.SchedStartTime.format('M/d/yyyy', resolveDisplayTz(ctx));
    }

    private static String scheduledDateTimeLabel(ServiceAppointment sa, MeetingContext ctx) {
        if (sa.SchedStartTime == null) return '';
        return sa.SchedStartTime.format('M/d/yyyy h:mm a z', resolveDisplayTz(ctx));
    }

    // Builds the email subject; CANCEL/RESCHEDULE prefix "Re:" so clients thread with the original CREATE.
    private static String buildSubject(
        ZoomMeetingEmailService.InviteType t, ServiceAppointment sa, MeetingContext ctx
    ) {
        String studentName = studentFullName(sa, ctx);
        String hostName    = (ctx != null && ctx.host != null)
                             ? composeUserDisplayName(ctx.host) : '';
        if (String.isBlank(hostName)) hostName = ORG_SENDER_NAME;
        String dateLabel   = scheduledDateLabel(sa, ctx);

        String coreSubject = 'Zenith Meeting Scheduled: ' + studentName + ' with ' + hostName
                           + (String.isBlank(dateLabel) ? '' : ' on ' + dateLabel);

        if (t == ZoomMeetingEmailService.InviteType.CANCELLATION
            || t == ZoomMeetingEmailService.InviteType.RESCHEDULE) {
            return 'Re: ' + coreSubject;
        }
        return coreSubject;
    }

    // Builds the HTML body for create / reschedule / cancellation emails (Apex fallback when no Lightning template applies).
    private static String buildHtmlBody(
        ZoomMeetingEmailService.InviteType t, ServiceAppointment sa,
        MeetingContext ctx, String zoomInvitationText
    ) {
        String firstName = String.escapeSingleQuotes(studentFirstName(sa, ctx));
        String resolvedHostName = (ctx != null && ctx.host != null)
            ? composeUserDisplayName(ctx.host) : '';
        if (String.isBlank(resolvedHostName)) resolvedHostName = ORG_SENDER_NAME;
        String hostName  = String.escapeSingleQuotes(resolvedHostName);
        String timeLabel = scheduledDateTimeLabel(sa, ctx);
        String joinUrl   = (sa.Zoom_Join_URL__c != null) ? sa.Zoom_Join_URL__c : sa.Zoom_Link__c;
        if (joinUrl == null) joinUrl = '';

        String style = 'font-family:Arial,sans-serif;font-size:11pt;color:#000000;line-height:1.45;';
        String html  = '<div style="' + style + '">';
        html += '<p>Dear <strong>' + firstName + '</strong>,</p>';
        html += '<p>&nbsp;</p>';

        if (t == ZoomMeetingEmailService.InviteType.CANCELLATION) {
            html += '<p>Your Zenith meeting with <strong>' + hostName
                 +  '</strong>' + (String.isBlank(timeLabel) ? '' : ' on <strong>' + timeLabel + '</strong>')
                 +  ' has been <strong>cancelled</strong>.</p>';
            html += '<p>This event has been removed from your calendar.</p>';
        } else {
            String intro = (t == ZoomMeetingEmailService.InviteType.RESCHEDULE)
                ? 'Your Zenith meeting has been rescheduled. You now have a Zenith meeting scheduled with '
                : 'This is a reminder that you have a Zenith meeting scheduled with ';
            html += '<p>' + intro + '<strong>' + hostName + '</strong>'
                 +  (String.isBlank(timeLabel) ? '.' : ' on <strong>' + timeLabel + '.</strong>') + '</p>';
            html += '<p>&nbsp;</p>';
            if (String.isNotBlank(joinUrl)) {
                html += '<p>The link for your meeting is: <a href="' + joinUrl + '">' + joinUrl + '</a></p>';
                html += '<p>&nbsp;</p>';
            }
            if (t == ZoomMeetingEmailService.InviteType.NEW_BOOKING) {
                html += '<p>As a reminder, at least 72 hours (3 days) before your meeting please do the following:</p>';
                html += '<ul>';
                html += '<li>Update the status of any action items in the portal (if you have not already).</li>';
                html += '<li>Send your Educational Strategist an email with relevant updates on offense and defense.</li>';
                html += '</ul>';
                html += '<p>Failing to send these updates at least 72 hours before the meeting means that your '
                     +  'Zenith Strategist will need to spend valuable time getting up to speed on your case. '
                     +  'Sending these updates in advance of the meeting will ensure that your time together '
                     +  'can be as forward looking and proactive as possible.</p>';
                html += '<p>&nbsp;</p>';
            }
        }

        html += '<p>Best wishes,</p>';
        html += '<p>Zenith Operations</p>';
        html += '</div>';
        return html;
    }

    // Builds the plain-text body mirroring buildHtmlBody for non-HTML email clients.
    private static String buildPlainBody(
        ZoomMeetingEmailService.InviteType t, ServiceAppointment sa,
        MeetingContext ctx, String zoomInvitationText
    ) {
        String firstName = studentFirstName(sa, ctx);
        String hostName  = (ctx != null && ctx.host != null)
                           ? composeUserDisplayName(ctx.host) : '';
        if (String.isBlank(hostName)) hostName = ORG_SENDER_NAME;
        String timeLabel = scheduledDateTimeLabel(sa, ctx);
        String joinUrl   = (sa.Zoom_Join_URL__c != null) ? sa.Zoom_Join_URL__c : sa.Zoom_Link__c;
        if (joinUrl == null) joinUrl = '';

        String body = 'Dear ' + firstName + ',\n\n';

        if (t == ZoomMeetingEmailService.InviteType.CANCELLATION) {
            body += 'Your Zenith meeting with ' + hostName
                 +  (String.isBlank(timeLabel) ? '' : ' on ' + timeLabel)
                 +  ' has been cancelled.\n\n';
            body += 'This event has been removed from your calendar.\n\n';
            body += 'Best wishes,\nZenith Operations\n';
            return body;
        }

        String intro = (t == ZoomMeetingEmailService.InviteType.RESCHEDULE)
            ? 'Your Zenith meeting has been rescheduled. You now have a Zenith meeting scheduled with '
            : 'This is a reminder that you have a Zenith meeting scheduled with ';
        body += intro + hostName
             +  (String.isBlank(timeLabel) ? '.' : ' on ' + timeLabel + '.') + '\n\n';

        if (String.isNotBlank(joinUrl)) {
            body += 'The link for your meeting is: ' + joinUrl + '\n\n';
        }

        if (t == ZoomMeetingEmailService.InviteType.NEW_BOOKING) {
            body += 'As a reminder, at least 72 hours (3 days) before your meeting please do the following:\n';
            body += '  - Update the status of any action items in the portal (if you have not already).\n';
            body += '  - Send your Educational Strategist an email with relevant updates on offense and defense.\n\n';
            body += 'Failing to send these updates at least 72 hours before the meeting means that your Zenith '
                 +  'Strategist will need to spend valuable time getting up to speed on your case. Sending these '
                 +  'updates in advance of the meeting will ensure that your time together can be as forward '
                 +  'looking and proactive as possible.\n\n';
        }

        body += 'Best wishes,\nZenith Operations\n';
        return body;
    }

    // Formats the SA's start/end time as a single human-readable label in the host's tz.
    private static String buildTimeRangeLabel(ServiceAppointment sa, MeetingContext ctx) {
        if (sa.SchedStartTime == null || sa.SchedEndTime == null) return '';
        String tz = resolveDisplayTz(ctx);
        String startLong = sa.SchedStartTime.format('EEE d MMM yyyy h:mma', tz);
        String endFull   = sa.SchedEndTime.format('EEE d MMM yyyy h:mma', tz);
        String endShort  = sa.SchedEndTime.format('h:mma', tz);
        String tzAbbr    = sa.SchedEndTime.format('z', tz);

        String startDay = sa.SchedStartTime.format('yyyyMMdd', tz);
        String endDay   = sa.SchedEndTime.format('yyyyMMdd', tz);

        if (startDay == endDay) return startLong + ' - ' + endShort + ' (' + tzAbbr + ')';
        return startLong + ' - ' + endFull + ' (' + tzAbbr + ')';
    }

    private static String resolveDisplayTz(MeetingContext ctx) {
        if (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.TimeZoneSidKey)) {
            return ctx.host.TimeZoneSidKey;
        }
        return UserInfo.getTimeZone().getID();
    }

    // Escapes HTML and turns any http(s) URLs into anchor tags for safe rendering inside email bodies.
    private static String linkifyAndEscape(String raw) {
        if (String.isBlank(raw)) return '';
        String s = raw.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;');
        Pattern urlPat = Pattern.compile('(https?://[^\\s<]+)');
        Matcher m = urlPat.matcher(s);
        String result = '';
        Integer last = 0;
        while (m.find()) {
            result += s.substring(last, m.start());
            String url = m.group(1);
            String trailing = '';
            while (url.length() > 0 && (url.endsWith('.') || url.endsWith(',') || url.endsWith(')'))) {
                trailing = url.substring(url.length() - 1) + trailing;
                url = url.substring(0, url.length() - 1);
            }
            result += '<a href="' + url + '" style="color:#1a73e8;text-decoration:none;">'
                   + url + '</a>' + trailing;
            last = m.end();
        }
        result += s.substring(last);
        return result;
    }

    private static String computeIcsUid(ServiceAppointment sa) {
        return 'sa-' + String.valueOf(sa.Id) + ICS_UID_DOMAIN;
    }

    // Derives a strictly-increasing ICS SEQUENCE from the SA's CreatedDate/SystemModstamp delta.
    private static Integer deriveSequence(ServiceAppointment sa) {
        if (sa == null || sa.SystemModstamp == null || sa.CreatedDate == null) return 0;
        Long deltaMs = sa.SystemModstamp.getTime() - sa.CreatedDate.getTime();
        if (deltaMs <= 0) return 0;
        return (Integer) (deltaMs / 1000L);
    }

    // Formats a raw Zoom meeting id into space-separated 3-digit groups.
    private static String formatMeetingId(String rawId) {
        if (String.isBlank(rawId)) return '';
        String digits = rawId.replaceAll('[^0-9]', '');
        List<String> groups = new List<String>();
        Integer i = 0;
        while (i < digits.length()) {
            Integer endIdx = Math.min(i + 3, digits.length());
            groups.add(digits.substring(i, endIdx));
            i = endIdx;
        }
        return String.join(groups, ' ');
    }

    // Loads SAs with all role/relationship fields needed downstream; built dynamically so optional fields are only requested when they exist.
    private static Map<Id, ServiceAppointment> loadAppointments(Set<Id> saIds) {
        String soql =
            'SELECT Id, Subject, SchedStartTime, SchedEndTime, Status, '
          + '       Meeting_Type__c, Email, Phone, '
          + '       Zoom_Meeting_ID__c, Zoom_Link__c, Zoom_Join_URL__c, Zoom_Start_URL__c, '
          + '       CreatedDate, SystemModstamp, '
          + '       ContactId, '
          + '       Contact.Id, Contact.Name, Contact.Email, Contact.AccountId, '
          + '       Contact.Counselor__c, '
          + '       Contact.Counselor__r.Name, Contact.Counselor__r.FirstName, Contact.Counselor__r.LastName, Contact.Counselor__r.Email, Contact.Counselor__r.TimeZoneSidKey, '
          + '       Contact.Substitute_Counselor__c, '
          + '       Contact.Substitute_Counselor__r.Name, Contact.Substitute_Counselor__r.FirstName, Contact.Substitute_Counselor__r.LastName, Contact.Substitute_Counselor__r.Email, Contact.Substitute_Counselor__r.TimeZoneSidKey, '
          + '       Contact.Program_Director__c, '
          + '       Contact.Program_Director__r.Name, Contact.Program_Director__r.FirstName, Contact.Program_Director__r.LastName, Contact.Program_Director__r.Email, Contact.Program_Director__r.TimeZoneSidKey, '
          + '       Contact.Family_Success_Specialist__c, '
          + '       Contact.Family_Success_Specialist__r.Name, Contact.Family_Success_Specialist__r.FirstName, Contact.Family_Success_Specialist__r.LastName, Contact.Family_Success_Specialist__r.Email, Contact.Family_Success_Specialist__r.TimeZoneSidKey, '
          + '       Contact.IC_admissions_counselor__c, '
          + '       Contact.IC_admissions_counselor__r.Name, Contact.IC_admissions_counselor__r.FirstName, Contact.IC_admissions_counselor__r.LastName, Contact.IC_admissions_counselor__r.Email, Contact.IC_admissions_counselor__r.TimeZoneSidKey, '
          + '       Educational_Strategist__c, '
          + '       Educational_Strategist__r.Name, Educational_Strategist__r.FirstName, Educational_Strategist__r.LastName, Educational_Strategist__r.Email, Educational_Strategist__r.TimeZoneSidKey, '
          + '       Admission_Counselor__c, '
          + '       Admission_Counselor__r.Name, Admission_Counselor__r.FirstName, Admission_Counselor__r.LastName, Admission_Counselor__r.Email, Admission_Counselor__r.TimeZoneSidKey, '
          + '       Program_Director__c, '
          + '       Program_Director__r.Name, Program_Director__r.FirstName, Program_Director__r.LastName, Program_Director__r.Email, Program_Director__r.TimeZoneSidKey, '
          + '       Family_Success_Specialist__c, '
          + '       Family_Success_Specialist__r.Name, Family_Success_Specialist__r.FirstName, Family_Success_Specialist__r.LastName, Family_Success_Specialist__r.Email, Family_Success_Specialist__r.TimeZoneSidKey, '
          + '       ParentRecordId, ParentRecordType, '
          + '       Opportunity__c, '
          + '       OwnerId'
          + (hasGuestEmailsField() ? ', Lead__r.Guest_Emails__c ' : ' ')
          + 'FROM ServiceAppointment WHERE Id IN :saIds';
        return new Map<Id, ServiceAppointment>(
            (List<ServiceAppointment>) Database.query(soql)
        );
    }

    // Loads the parent Lead records for any Lead-parented SAs in the batch.
    private static Map<Id, Lead> loadParentLeads(List<ServiceAppointment> sas) {
        Set<Id> leadIds = new Set<Id>();
        for (ServiceAppointment sa : sas) {
            if (sa.ParentRecordType == 'Lead' && sa.ParentRecordId != null) {
                leadIds.add(sa.ParentRecordId);
            }
        }
        if (leadIds.isEmpty()) return new Map<Id, Lead>();
        return new Map<Id, Lead>([
            SELECT Id, FirstName, LastName, Name, Email, Company, OwnerId,
                   Parent_1_Email__c, Parent_2_Email__c,
                   Assigned_Admission_Counsellor__c,
                   Assigned_Admission_Counsellor__r.Name,
                   Assigned_Admission_Counsellor__r.FirstName,
                   Assigned_Admission_Counsellor__r.LastName,
                   Assigned_Admission_Counsellor__r.Email,
                   Assigned_Admission_Counsellor__r.TimeZoneSidKey,
                   Assigned_PD__c,
                   Assigned_PD__r.Name,
                   Assigned_PD__r.FirstName,
                   Assigned_PD__r.LastName,
                   Assigned_PD__r.Email,
                   Assigned_PD__r.TimeZoneSidKey
            FROM Lead
            WHERE Id IN :leadIds
        ]);
    }

    // Loads verified Parent contacts grouped by AccountId for use as CC recipients.
    private static Map<Id, List<Contact>> loadVerifiedParents(List<ServiceAppointment> sas) {
        Set<Id> acctIds = new Set<Id>();
        for (ServiceAppointment sa : sas) {
            if (sa.Contact != null && sa.Contact.AccountId != null) acctIds.add(sa.Contact.AccountId);
        }
        Map<Id, List<Contact>> out = new Map<Id, List<Contact>>();
        if (acctIds.isEmpty()) return out;

        for (Contact p : [
            SELECT Id, Name, Email, AccountId
            FROM Contact
            WHERE AccountId IN :acctIds
              AND Record_Type__c = 'Parent'
              AND Parent_Verified__c = true
              AND Email != null
        ]) {
            if (!out.containsKey(p.AccountId)) out.put(p.AccountId, new List<Contact>());
            out.get(p.AccountId).add(p);
        }
        return out;
    }

    // Loads active Substitute__c records keyed by Contact id for ES-host override.
    @TestVisible
    private static Map<Id, User> loadActiveSubstitutes(List<ServiceAppointment> sas) {
        Set<Id> contactIds = new Set<Id>();
        for (ServiceAppointment sa : sas) {
            if (sa.ContactId != null) contactIds.add(sa.ContactId);
        }
        Map<Id, User> out = new Map<Id, User>();
        if (contactIds.isEmpty()) return out;
        for (Substitute__c s : [
            SELECT Contact__c,
                   Substitute_Educational_Strategist__c,
                   Substitute_Educational_Strategist__r.Name,
                   Substitute_Educational_Strategist__r.FirstName,
                   Substitute_Educational_Strategist__r.LastName,
                   Substitute_Educational_Strategist__r.Email,
                   Substitute_Educational_Strategist__r.TimeZoneSidKey
            FROM Substitute__c
            WHERE Contact__c IN :contactIds
              AND Active__c = true
              AND Substitute_Educational_Strategist__c != null
            ORDER BY LastModifiedDate DESC
        ]) {
            if (!out.containsKey(s.Contact__c) && s.Substitute_Educational_Strategist__r != null) {
                out.put(s.Contact__c, s.Substitute_Educational_Strategist__r);
            }
        }
        return out;
    }

    // Loads User-typed Owners (SA + Lead) for owner-fallback host resolution.
    private static Map<Id, User> loadOwnerUsers(List<ServiceAppointment> sas, Map<Id, Lead> leadsById) {
        Set<Id> userOwnerIds = new Set<Id>();
        for (ServiceAppointment sa : sas) {
            if (sa.OwnerId != null && String.valueOf(sa.OwnerId).startsWith('005')) {
                userOwnerIds.add(sa.OwnerId);
            }
        }
        for (Lead l : leadsById.values()) {
            if (l.OwnerId != null && String.valueOf(l.OwnerId).startsWith('005')) {
                userOwnerIds.add(l.OwnerId);
            }
        }
        if (userOwnerIds.isEmpty()) return new Map<Id, User>();
        return new Map<Id, User>([
            SELECT Id, Name, FirstName, LastName, Email, TimeZoneSidKey
            FROM User
            WHERE Id IN :userOwnerIds
        ]);
    }

    // Looks up the OrgWideEmailAddress id for the configured branded sender.
    private static Id lookupOrgWideEmailId(String addr) {
        try {
            List<OrgWideEmailAddress> rows = [
                SELECT Id FROM OrgWideEmailAddress WHERE Address = :addr LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0].Id;
        } catch (Exception e) {
            return null;
        }
    }
}