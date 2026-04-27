/**
 * @File Name          : ZoomMeetingManager.cls
 * @Description        : Invocable Apex class used by Salesforce Flows to manage
 *                       the full lifecycle of a Zoom meeting tied to a
 *                       ServiceAppointment record.
 *
 *                       Three actions:
 *                          CREATE  — create the Zoom meeting and email a first
 *                                    .ics invite (METHOD:REQUEST, SEQUENCE:0)
 *                          UPDATE  — reschedule the existing Zoom meeting and
 *                                    email a REPLACE invite (same UID,
 *                                    SEQUENCE incremented)
 *                          CANCEL  — delete the Zoom meeting and email a
 *                                    METHOD:CANCEL invite to remove the event
 *                                    from the family's calendar
 *
 *                       DYNAMIC HOST RESOLUTION
 *                       --------------------------------------------------------
 *                       The Zoom meeting host is resolved from the Service
 *                       Appointment based on the role implied by
 *                       Meeting_Type__c / Subject, so any profile can create
 *                       SAs and have meetings host themselves:
 *
 *                            Meeting role             Primary host source
 *                            ------------------------ --------------------------------
 *                            Initial Consultation /   SA.Admission_Counselor__c
 *                              IC / Admission         -> Contact.IC_admissions_counselor__c
 *                                                     -> Lead.Assigned_Admission_Counsellor__c
 *
 *                            FSS / Family Success /   SA.Family_Success_Specialist__c
 *                              Onboarding             -> Contact.Family_Success_Specialist__c
 *
 *                            Program Director         SA.Program_Director__c
 *                                                     -> Contact.Program_Director__c
 *                                                     -> Lead.Assigned_PD__c
 *
 *                            Educational Strategist / SA.Educational_Strategist__c
 *                              Regular (default)      -> Contact.Counselor__c
 *                                                       (the Contact field is labelled
 *                                                        "Educational Strategist")
 *
 *                       Fallback in all cases: SA.Owner (if Owner is a User),
 *                       so the class "just works" regardless of the creator's
 *                       profile.
 *
 *                       LEAD-PARENTED APPOINTMENTS
 *                       --------------------------------------------------------
 *                       When a Service Appointment is created against a Lead
 *                       (pre-conversion), SA.ContactId is blank and the record
 *                       is linked through SA.ParentRecordId / SA.ParentRecordType='Lead'.
 *                       This class reads the Lead when necessary so the Zoom
 *                       meeting and .ics invite still go out correctly.
 *
 *                       BACKWARD COMPATIBILITY
 *                       --------------------------------------------------------
 *                       The output wrapper keeps the old public fields
 *                       (meetingUrl, joinUrl, startUrl, meetingId, hostEmail,
 *                       status, errorMessage) exactly as the previous
 *                       `GetZoomMeetingURLwithInput` class, so the current
 *                       Flow continues to work unchanged for CREATE.
 *
 *                       DML / CALLOUT ORDERING
 *                       --------------------------------------------------------
 *                       Only SOQL (reads) run before the Zoom callout. The Flow
 *                       owns the subsequent UPDATE of the ServiceAppointment
 *                       record, writing back the output variables below. This
 *                       keeps us compliant with "no DML before callout".
 *
 * @Author             : Amit Yadav
 * @Created On         : April 2026
 */
// `without sharing` is required because Meeting_After_RTF runs in the
// post-commit context of the originating user (often the Site Guest User
// `zenith_booking@…` for IC bookings). After insert, the SA's OwnerId is
// reassigned to the Admission Counselor, so the guest user no longer has
// row visibility under `with sharing` — the SA-load SOQL returns 0 rows
// and the Zoom callout is skipped, which silently broke the IC email
// pipeline (no Zoom_Link__c stamped → flow never fires the email branch).
// The class only reads SA + role users and writes back via Zoom callout +
// the flow's own SA UPDATE, so this does not grant the guest user any
// new write access.
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

    /** Lightning "Zenith Meeting Scheduled" template — drives the branded
     *  subject + HTML body on CREATE for Contact-based SAs, so admin edits
     *  in Setup propagate without a code deploy. */
    private static final Id SCHEDULED_EMAIL_TEMPLATE_ID   = '00XQU00000ARwzs';
    /** Lightning "Initial Consultation Meeting Scheduled" template — used
     *  for Lead-based SAs (IC bookings) so the IC-specific copy and links
     *  go to the prospect. Org-specific Id; update when deploying to other
     *  environments. Setup → Email Templates → Initial Consultation
     *  Meeting Scheduled. */
    private static final Id IC_SCHEDULED_EMAIL_TEMPLATE_ID = '00Xbb0000031aCbEAI';
    /** Lightning "Meeting Rescheduled Email Template" (Enhanced) — carries
     *  the Zenith Prep Lightning Letterhead via Setup, so admin edits to
     *  copy / branding propagate without a code deploy. Used for RESCHEDULE
     *  emails. Setup → Email Templates → Meeting Rescheduled Email Template. */
    private static final Id RESCHEDULED_EMAIL_TEMPLATE_ID = '00Xbb000003UJbN';

    private static final String ROLE_ES  = 'ES';
    private static final String ROLE_AC  = 'AC';
    private static final String ROLE_PD  = 'PD';
    private static final String ROLE_FSS = 'FSS';

    // =========================================================================
    //  INPUT / OUTPUT WRAPPERS
    // =========================================================================
    public class InputWrapper {
        @InvocableVariable(required=true label='Service Appointment Id')
        public Id serviceAppointmentId;

        @InvocableVariable(
            required=false
            label='Action'
            description='CREATE (default) | UPDATE (reschedule) | CANCEL')
        public String action;
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

    // =========================================================================
    //  INVOCABLE ENTRY POINT
    // =========================================================================
    @InvocableMethod(
        label='Manage Zoom Meeting + Calendar Invite'
        description='Create / Reschedule / Cancel a Zoom meeting. Host is resolved dynamically from the SA role fields (Educational Strategist, Admission Counselor, Program Director, Family Success Specialist), with Owner as fallback.'
        callout=true)
    public static List<OutputWrapper> manage(List<InputWrapper> inputs) {

        List<OutputWrapper> outputs = new List<OutputWrapper>();
        if (inputs == null || inputs.isEmpty()) return outputs;

        Set<Id> saIds = new Set<Id>();
        for (InputWrapper ip : inputs) {
            if (ip != null && ip.serviceAppointmentId != null) saIds.add(ip.serviceAppointmentId);
        }
        if (saIds.isEmpty()) return outputs;

        Map<Id, ServiceAppointment> saMap         = loadAppointments(saIds);
        Map<Id, Lead>               leadsById     = loadParentLeads(saMap.values());
        Map<Id, List<Contact>>      parentsByAcct = loadVerifiedParents(saMap.values());
        Map<Id, User>               ownerUsers    = loadOwnerUsers(saMap.values(), leadsById);
        Map<Id, User>               substitutes   = loadActiveSubstitutes(saMap.values());
        Id                          orgWideId     = lookupOrgWideEmailId(ORG_SENDER_ADDRESS);

        Http http = new Http();

        // Collect every email across every input and send them in ONE
        // Messaging.sendEmail call after the loop. This keeps us inside
        // the 10-email-invocations-per-transaction governor limit no
        // matter how many SAs the flow batches into manage().
        List<ZoomMeetingEmailService.SendInput> emailBatch = new List<ZoomMeetingEmailService.SendInput>();
        List<OutputWrapper> emailOwners = new List<OutputWrapper>();

        // SAs whose Zoom fields were freshly hydrated and need to be persisted
        // BEFORE the emails go out — Messaging.renderStoredEmailTemplate reads
        // merge values from the DB, so Zoom_Link__c must already be saved or
        // the link won't appear in the rendered template body.
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

                dispatch(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners, sasToPersist);

            } catch (Exception e) {
                out.status = STATUS_ERROR;
                out.errorMessage = 'Unhandled: ' + e.getMessage() + ' @ ' + e.getStackTraceString();
            }
        }

        if (!sasToPersist.isEmpty()) {
            // Bulk DML before email render. Safe under the parent flow because
            // Create_Meeting_Zoom_Link_And_Send_Reminders is RecordAfterSave on
            // CREATE only — an update here doesn't re-trigger it.
            update sasToPersist.values();
        }

        deliverEmailBatch(emailBatch, emailOwners);
        return outputs;
    }

    /**
     * Send the Zenith Meeting Scheduled email + .ics for SAs whose Zoom
     * meeting is already created and persisted. Invoked from
     * Meeting_After_RTF → Send_Meeting_Scheduled_Email_notification so the
     * flow drives the booking confirmation while still attaching the .ics
     * (emailSimple alone can't attach files). Skips SAs that don't yet have
     * Zoom_Meeting_ID__c / a join URL to avoid sending blank-link invites.
     */
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
            // Only require a join URL — Zoom_Meeting_ID__c is no longer
            // mandatory because some org flows stamp Zoom_Link__c without
            // also stamping Zoom_Meeting_ID__c, which previously caused a
            // SILENT skip and was the reason IC emails never arrived even
            // though the Zoom link was set on the SA. computeIcsUid() uses
            // sa.Id so the .ics is still uniquely identified.
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

            // ----- Email 1: family — student (TO) + verified parents (CC) -----
            // METHOD:REQUEST renders the Yes/No/Maybe widget on Gmail and
            // shows the host as ORGANIZER on the attendees' calendars.
            String familyIcs = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_REQUEST,
                                        joinUrl, sa.Zoom_Meeting_ID__c, null, parentsByAcct);
            emailBatch.add(buildFamilySendInput(sa, ctx, parentsByAcct, orgWideId, familyIcs));
            emailOwners.add(owner);

            // ----- Email 2: host (ES / Sub-ES / role user) -----
            // Gmail won't auto-add events when the recipient's email matches
            // ORGANIZER's mailto (it expects the organizer to already have
            // the event on their calendar). To get auto-add behaviour for
            // the host's own copy, we override ORGANIZER's mailto to the
            // org-wide info@... address (the SMTP From) — the CN parameter
            // still carries the ES's name, so the host's calendar entry
            // displays "Organized by [ES Name]". Their ATTENDEE entry
            // already has PARTSTAT=ACCEPTED so the event lands as confirmed
            // without an RSVP prompt.
            if (ctx.host != null && String.isNotBlank(ctx.host.Email)) {
                String hostIcs = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_REQUEST,
                                          joinUrl, sa.Zoom_Meeting_ID__c, null, parentsByAcct,
                                          ORG_SENDER_ADDRESS);
                emailBatch.add(buildHostSendInput(sa, ctx, orgWideId, hostIcs));
                emailOwners.add(owner);
            }
        }

        deliverEmailBatch(emailBatch, emailOwners);
    }

    /**
     * Family-side SendInput: TO=student, CC=verified parents (host omitted —
     * they receive their own dedicated PUBLISH-method email).
     */
    private static ZoomMeetingEmailService.SendInput buildFamilySendInput(
        ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, String ics
    ) {
        ZoomMeetingEmailService.SendInput sin = new ZoomMeetingEmailService.SendInput();
        sin.inviteType    = ZoomMeetingEmailService.InviteType.NEW_BOOKING;
        sin.icsContent    = ics;
        sin.toEmail       = ctx.attendeeEmail;
        // CC = verified parents (Contact-based) + counselor + booking guests
        // (the Add-guests list captured at booking time, stored in the SA's
        // Guest_Emails__c text field as comma-separated addresses).
        sin.ccEmails      = buildFamilyCcList(sa, ctx, parentsByAcct);
        sin.orgWideEmailId = orgWideId;
        sin.relatedWhatId  = sa.Id;
        // For Lead-based SAs (IC bookings), there's no ContactId — fall back
        // to the Lead Id so Messaging.renderStoredEmailTemplate can resolve
        // recipient-aware merge fields ({{{Recipient.FirstName}}} etc.) and
        // the "Initial Consultation Meeting Scheduled" lightning template
        // renders for Lead recipients too. The template's ServiceAppointment
        // merge fields resolve via relatedWhatId regardless.
        Id targetId = sa.ContactId != null
                      ? sa.ContactId
                      : ((sa.ParentRecordType == 'Lead') ? sa.ParentRecordId : null);
        sin.targetObjectId = targetId;
        sin.logEmailOnSend = (targetId != null);
        Boolean isLeadBased = sa.ContactId == null && sa.ParentRecordType == 'Lead';
        if (targetId != null) {
            // Lead-based IC bookings get the "Initial Consultation Meeting
            // Scheduled" template (prospect-facing copy + links). Contact-based
            // bookings keep the existing "Zenith Meeting Scheduled" template
            // unchanged.
            sin.templateId = isLeadBased
                ? IC_SCHEDULED_EMAIL_TEMPLATE_ID
                : SCHEDULED_EMAIL_TEMPLATE_ID;
        } else {
            sin.subject   = buildSubject(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx);
            sin.htmlBody  = buildHtmlBody(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx, null);
            sin.plainBody = buildPlainBody(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx, null);
        }
        return sin;
    }

    /**
     * Host-side SendInput: TO=host, no CC. Carries the same Lightning-
     * template body as the family copy but the .ics has its ORGANIZER
     * mailto overridden to info@... (CN still says the ES's name). Without
     * the override, Gmail's organizer-recipient logic refuses to auto-add —
     * with it, the host's email no longer matches ORGANIZER and the
     * calendar imports the event automatically (their ATTENDEE entry is
     * marked ACCEPTED so no RSVP prompt). Activity logging is forced off —
     * Tasks can't be saved against a User Who.
     */
    private static ZoomMeetingEmailService.SendInput buildHostSendInput(
        ServiceAppointment sa, MeetingContext ctx, Id orgWideId, String ics
    ) {
        ZoomMeetingEmailService.SendInput sin = new ZoomMeetingEmailService.SendInput();
        sin.inviteType    = ZoomMeetingEmailService.InviteType.NEW_BOOKING;
        sin.icsContent    = ics;
        sin.toEmail       = ctx.host.Email;
        sin.ccEmails      = new List<String>();
        sin.orgWideEmailId = orgWideId;
        sin.relatedWhatId  = sa.Id;
        // Use sa.ContactId for merge-field resolution on the template (the
        // body is keyed off the student's data); the User host is the
        // recipient via setToAddresses, not the targetObject.
        sin.targetObjectId = sa.ContactId;
        sin.logEmailOnSend = false;
        if (sa.ContactId != null) {
            sin.templateId = SCHEDULED_EMAIL_TEMPLATE_ID;
        } else {
            sin.subject   = buildSubject(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx);
            sin.htmlBody  = buildHtmlBody(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx, null);
            sin.plainBody = buildPlainBody(ZoomMeetingEmailService.InviteType.NEW_BOOKING, sa, ctx, null);
        }
        return sin;
    }

    /** CC list with only verified parents — host is excluded so they get their
     *  own dedicated PUBLISH-method email instead of being CC'd here. */
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

    /**
     * Family-side CC list = verified parents + assigned counselor + invited
     * guests captured at booking time. Host is intentionally NOT in this list
     * — they receive a dedicated PUBLISH-method email so Gmail auto-adds the
     * event. Dedup + casing is handled by ZoomMeetingEmailService.dedupAndClean.
     */
    private static List<String> buildFamilyCcList(
        ServiceAppointment sa, MeetingContext ctx, Map<Id, List<Contact>> parentsByAcct
    ) {
        List<String> out = new List<String>();
        // 1. Verified parent contacts (Contact-based SAs only)
        out.addAll(parentsOnlyCcList(ctx, parentsByAcct));
        // 2. Booking guests — Add-guests field on the SA, comma-separated.
        //    Read via dynamic SObject.get() so this class still compiles in
        //    orgs that haven't created Guest_Emails__c yet (loadAppointments
        //    only adds the field to its SELECT when describe says it exists).
        String guestStr = readGuestEmails(sa);
        if (String.isNotBlank(guestStr)) {
            for (String raw : guestStr.split(',')) {
                if (raw == null) continue;
                String trimmed = raw.trim();
                if (String.isNotBlank(trimmed)) out.add(trimmed);
            }
        }
        // 3. Lead Owner — for Lead-based SAs (IC bookings), CC the assigned
        //    counselor (= Lead.Owner User, resolved into ctx.host) on the
        //    family confirmation so they have a thread copy. Contact-based
        //    paths intentionally skip this — they keep the existing CC
        //    behaviour (verified parents + guests).
        Boolean isLeadBased = sa.ContactId == null && sa.ParentRecordType == 'Lead';
        if (isLeadBased && ctx != null && ctx.host != null
            && String.isNotBlank(ctx.host.Email)) {
            out.add(ctx.host.Email);
        }
        return out;
    }

    /** Schema-cached: does ServiceAppointment.Guest_Emails__c exist? */
    private static Boolean guestEmailsResolved = false;
    private static Boolean guestEmailsCache = false;
    private static Boolean hasGuestEmailsField() {
        if (guestEmailsResolved) return guestEmailsCache;
        guestEmailsResolved = true;
        try {
            guestEmailsCache = Schema.SObjectType.ServiceAppointment.fields
                .getMap().containsKey('guest_emails__c');
        } catch (Exception e) { guestEmailsCache = false; }
        return guestEmailsCache;
    }

    /** Read Guest_Emails__c off an SA without compile-time field reference. */
    private static String readGuestEmails(ServiceAppointment sa) {
        if (sa == null || !hasGuestEmailsField()) return null;
        try {
            Object v = sa.get('Guest_Emails__c');
            return (v instanceof String) ? (String) v : null;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Send cancellation emails for SAs whose meeting has been canceled. The
     * email body comes from the Setup-side Lightning template chosen by the
     * caller (Service_Appointment_Status_Change_Email_Notification picks the
     * right template based on who cancelled). The .ics is METHOD:CANCEL so
     * Gmail / Outlook / Apple Calendar remove the event from every
     * recipient's calendar. Driven from the flow via
     * ZoomMeetingCancelEmailAction so emailSimple's missing-attachment
     * limitation doesn't leave orphaned calendar events.
     */
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
            // Skip cancel email for SAs that never had a Zoom meeting — the
            // METHOD:CANCEL .ics references a UID no calendar ever saw, and
            // the email body claims the user had a meeting they never had.
            // Mirrors Zoom_Meeting_Update_Or_Cancel's `Zoom_Meeting_ID IsNull=false`
            // start filter so cancel-email behaviour matches Zoom-DELETE behaviour.
            if (String.isBlank(sa.Zoom_Meeting_ID__c)) continue;
            String joinUrl = String.isNotBlank(sa.Zoom_Join_URL__c) ? sa.Zoom_Join_URL__c : sa.Zoom_Link__c;

            MeetingContext ctx = resolveContext(sa, leadsById, ownerUsers, substitutes);
            if (ctx == null || String.isBlank(ctx.attendeeEmail)) continue;

            String uid = computeIcsUid(sa);
            Integer seq = deriveSequence(sa);

            String ics = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_CANCEL,
                                  joinUrl, sa.Zoom_Meeting_ID__c, null, parentsByAcct);

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
            sin.targetObjectId = sa.ContactId;
            sin.logEmailOnSend = (sa.ContactId != null);
            if (sa.ContactId != null) {
                sin.templateId = templateId;
            } else {
                sin.subject   = buildSubject(ZoomMeetingEmailService.InviteType.CANCELLATION, sa, ctx);
                sin.htmlBody  = buildHtmlBody(ZoomMeetingEmailService.InviteType.CANCELLATION, sa, ctx, null);
                sin.plainBody = buildPlainBody(ZoomMeetingEmailService.InviteType.CANCELLATION, sa, ctx, null);
            }
            emailBatch.add(sin);
            emailOwners.add(owner);
        }

        deliverEmailBatch(emailBatch, emailOwners);
    }

    /**
     * Bulk-send all invitations collected across the input batch and fold
     * each result back into its OutputWrapper. Single Messaging.sendEmail
     * call regardless of batch size.
     */
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
        List<ZoomMeetingEmailService.SendResult> results = ZoomMeetingEmailService.sendBulk(batch);
        for (Integer i = 0; i < results.size(); i++) {
            ZoomMeetingEmailService.SendResult r = results[i];
            OutputWrapper out = owners[i];
            out.icsInviteSent = r.success;
            if (r.success) {
                System.debug(LoggingLevel.INFO,
                    'deliverEmailBatch: msg ' + i + ' sent OK to ' + batch[i].toEmail);
            } else {
                // Surface the failure to the debug log every time — previously
                // it was only attached to the OutputWrapper, which is invisible
                // to the flow caller and made silent failures the norm for IC.
                System.debug(LoggingLevel.ERROR,
                    'deliverEmailBatch: msg ' + i + ' FAILED to ' + batch[i].toEmail +
                    ' — ' + r.errorMessage);
                if (String.isBlank(out.errorMessage)) {
                    out.errorMessage = 'Zoom action succeeded, but email failed: ' + r.errorMessage;
                }
            }
        }
    }

    // =========================================================================
    //  DISPATCH
    // =========================================================================
    private static void dispatch(
        OutputWrapper out, ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, Http http,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners,
        Map<Id, ServiceAppointment> sasToPersist
    ) {
        switch on out.action {
            when 'CREATE' { handleCreate(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners, sasToPersist); }
            when 'UPDATE' { handleUpdate(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners, sasToPersist); }
            when 'CANCEL' { handleCancel(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners); }
            when else {
                out.status = STATUS_ERROR;
                out.errorMessage = 'Unknown action: ' + out.action + '. Use CREATE | UPDATE | CANCEL.';
            }
        }
    }

    // =========================================================================
    //  ACTION: CREATE
    // =========================================================================
    private static void handleCreate(
        OutputWrapper out, ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, Http http,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners,
        Map<Id, ServiceAppointment> sasToPersist
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

        // Hydrate the in-memory SA with the freshly-created Zoom data and
        // queue it for DML BEFORE the email batch is sent — the email
        // template renders {{{ServiceAppointment.Zoom_Link__c}}} from the DB
        // value, so the link only appears if Zoom_Link__c is already saved.
        // The flow's later Update_Zoom_Links step is now idempotent for these.
        if (String.isBlank(sa.Zoom_Join_URL__c))  sa.Zoom_Join_URL__c  = out.joinUrl;
        if (String.isBlank(sa.Zoom_Link__c))      sa.Zoom_Link__c      = out.joinUrl;
        if (String.isBlank(sa.Zoom_Start_URL__c)) sa.Zoom_Start_URL__c = out.startUrl;
        if (String.isBlank(sa.Zoom_Meeting_ID__c)) sa.Zoom_Meeting_ID__c = out.meetingId;
        if (sasToPersist != null) sasToPersist.put(sa.Id, sa);

        String uid = computeIcsUid(sa);
        Integer seq = 0;
        out.icsUid      = uid;
        out.icsSequence = seq;

        // CREATE confirmation is sent by Meeting_After_RTF →
        // Send_Meeting_Scheduled_Email_notification (custom Apex action that
        // attaches the .ics — emailSimple alone can't). Skipping Apex-side
        // delivery here keeps booking confirmations to one email.
        // RESCHEDULE / CANCEL still send from Apex (handleUpdate / handleCancel)
        // because no flow path covers those lifecycle events.

        out.status = STATUS_SUCCESS;
    }

    // =========================================================================
    //  ACTION: UPDATE (reschedule)
    // =========================================================================
    private static void handleUpdate(
        OutputWrapper out, ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, Http http,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners,
        Map<Id, ServiceAppointment> sasToPersist
    ) {
        if (String.isBlank(sa.Zoom_Meeting_ID__c)) {
            out.action = ACTION_CREATE;
            handleCreate(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners, sasToPersist);
            return;
        }
        if (!validateForCreate(out, sa, ctx)) return;

        Map<String, Object> payload = buildZoomPayload(sa, ctx);
        String endpoint = NAMED_CREDENTIAL + '/meetings/' + sa.Zoom_Meeting_ID__c;
        HttpResponse res = doCallout(http, 'PATCH', endpoint, payload);

        if (res.getStatusCode() == 404) {
            out.action = ACTION_CREATE;
            handleCreate(out, sa, ctx, parentsByAcct, orgWideId, http, emailBatch, emailOwners, sasToPersist);
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

        String ics = buildIcs(sa, ctx, uid, seq, ZoomIcsBuilder.METHOD_REQUEST,
                              out.joinUrl, out.meetingId, zoomInvitationText, parentsByAcct);
        queueInvite(ZoomMeetingEmailService.InviteType.RESCHEDULE,
                    sa, ctx, parentsByAcct, orgWideId, ics, zoomInvitationText,
                    out, emailBatch, emailOwners);

        out.status = STATUS_SUCCESS;
    }

    // =========================================================================
    //  ACTION: CANCEL
    // =========================================================================
    private static void handleCancel(
        OutputWrapper out, ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct, Id orgWideId, Http http,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners
    ) {
        if (String.isBlank(sa.Zoom_Meeting_ID__c)) {
            out.status = STATUS_SKIPPED;
            out.errorMessage = 'No Zoom meeting found to cancel.';
            return;
        }

        if (String.isNotBlank(sa.Zoom_Meeting_ID__c)) {
            String endpoint = NAMED_CREDENTIAL + '/meetings/' + sa.Zoom_Meeting_ID__c
                            + '?schedule_for_reminder=false&cancel_meeting_reminder=true';
            HttpResponse res = doCallout(http, 'DELETE', endpoint, null);
            if (!isSuccess(res) && res.getStatusCode() != 404) {
                out.status = STATUS_ERROR;
                out.errorMessage = 'Zoom delete failed: ' + describe(res);
                return;
            }
        }

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

        // Cancellation email + METHOD:CANCEL .ics is now sent by
        // Service_Appointment_Status_Change_Email_Notification ->
        // Send_Cancellation_Email_Notification / Send_Client_Cancellation_Email
        // (both rewired to ZoomMeetingCancelEmailAction). The flow's decision
        // tree picks the right Lightning template based on Status — Apex no
        // longer hardcodes the cancel copy here, avoiding duplicate emails.

        out.status = STATUS_SUCCESS;
    }

    // =========================================================================
    //  HOST + ATTENDEE RESOLUTION
    // =========================================================================
    public class MeetingContext {
        public String role;
        public User   host;
        public String hostSource;
        public String attendeeName;
        public String attendeeEmail;
        public Id     accountIdForParents;
        public Lead   parentLead;
    }

    private static MeetingContext resolveContext(
        ServiceAppointment sa, Map<Id, Lead> leadsById, Map<Id, User> ownerUsers,
        Map<Id, User> substitutes
    ) {
        MeetingContext ctx = new MeetingContext();
        ctx.role = classifyMeetingRole(sa);

        if (sa.ParentRecordType == 'Lead' && sa.ParentRecordId != null) {
            ctx.parentLead = leadsById.get(sa.ParentRecordId);
        }

        // Attendee (primary recipient)
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

    private static void pickHost(
        MeetingContext ctx, ServiceAppointment sa,
        Map<Id, User> ownerUsers, Map<Id, User> substitutes
    ) {
        // 0. Active Substitute ES — only applies when role is ES. A student's
        // active Substitute__c record overrides the assigned Counselor__c so
        // the Zoom meeting runs on the substitute's Zoom license and the
        // invite shows the substitute as the organizer.
        if (ctx.role == ROLE_ES && sa.ContactId != null
            && substitutes != null && substitutes.containsKey(sa.ContactId)
            && isUsable(substitutes.get(sa.ContactId))) {
            ctx.host = substitutes.get(sa.ContactId);
            ctx.hostSource = 'Substitute__c.Active';
            return;
        }

        // 0a. Lead-based SA — the Lead's Owner is the natural organizer for
        // pre-conversion prospects. The Lead Owner took the lead and runs
        // the initial meeting, so they host on their Zoom license and
        // appear as the calendar invite organizer. This wins over the
        // role-based fallback chain below, which is designed for
        // post-conversion Contact SAs.
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

        // 1. SA-level role lookup
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

        // 2. Contact-level role lookup
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

        // 3. Lead-level role lookup
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

        // 4. Any populated role user on the SA (cross-role fallback)
        User anyRoleUser = firstUsable(new List<User>{
            sa.Educational_Strategist__r,
            sa.Admission_Counselor__r,
            sa.Program_Director__r,
            sa.Family_Success_Specialist__r
        });
        if (anyRoleUser != null) { ctx.host = anyRoleUser; ctx.hostSource = 'SA.AnyRole'; return; }

        // 5. SA Owner (if User)
        if (sa.OwnerId != null && ownerUsers.containsKey(sa.OwnerId)) {
            User owner = ownerUsers.get(sa.OwnerId);
            if (isUsable(owner)) { ctx.host = owner; ctx.hostSource = 'SA.Owner'; return; }
        }

        // 6. Lead Owner
        if (ctx.parentLead != null && ctx.parentLead.OwnerId != null
            && ownerUsers.containsKey(ctx.parentLead.OwnerId)) {
            User lo = ownerUsers.get(ctx.parentLead.OwnerId);
            if (isUsable(lo)) { ctx.host = lo; ctx.hostSource = 'Lead.Owner'; return; }
        }
    }

    private static Boolean isUsable(User u) {
        return u != null && String.isNotBlank(u.Email);
    }

    private static User firstUsable(List<User> candidates) {
        for (User u : candidates) if (isUsable(u)) return u;
        return null;
    }

    // =========================================================================
    //  ZOOM PAYLOAD
    // =========================================================================
    private static Map<String, Object> buildZoomPayload(ServiceAppointment sa, MeetingContext ctx) {
        Long durationMinutes =
            (sa.SchedEndTime.getTime() - sa.SchedStartTime.getTime()) / 60000L;
        String startTime = sa.SchedStartTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss') + 'Z';

        String tz = (ctx.host != null && String.isNotBlank(ctx.host.TimeZoneSidKey))
                    ? ctx.host.TimeZoneSidKey
                    : UserInfo.getTimeZone().getID();

        String topic  = buildTopic(sa, ctx);
        String hostName = (ctx.host != null && String.isNotBlank(ctx.host.Name))
                          ? ctx.host.Name : ORG_SENDER_NAME;
        String agenda = 'Meeting with ' + hostName;

        // No meeting_invitees / email_notification flags — we drive the
        // branded invitation email ourselves from Apex so Zoom stays silent
        // (no duplicate create / reschedule / cancel emails from Zoom).
        Map<String, Object> settings = new Map<String, Object>{
            'join_before_host' => false,
            'waiting_room'     => true,
            'mute_upon_entry'  => true
        };

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

    private static String buildTopic(ServiceAppointment sa, MeetingContext ctx) {
        if (String.isNotBlank(sa.Subject)) return sa.Subject;
        String mt = String.isBlank(sa.Meeting_Type__c) ? 'Meeting' : sa.Meeting_Type__c;
        String who = String.isNotBlank(ctx.attendeeName) ? ctx.attendeeName : '';
        return mt + (String.isBlank(who) ? '' : ' With ' + who);
    }

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

    // =========================================================================
    //  ZOOM-ONLY CANCELLATION (Join URL invalidation)
    // =========================================================================
    /**
     * Delete the Zoom meetings for the given SAs so the join URL in any
     * already-sent confirmation email stops working. Email/.ics cancellation
     * notice is NOT sent here — that's a separate concern handled by the
     * Meeting_After_RTF flow when the SA's Status flips. This method is
     * the surgical "expire the Zoom URL" hook for the family-cancel flow,
     * where we already have the SA marked Canceled and just need the Zoom
     * URL invalidated.
     *
     * Skips SAs without a Zoom_Meeting_ID__c (nothing to delete). 404s from
     * Zoom are treated as success (the meeting is already gone). Failures
     * are logged at WARN and swallowed — the calling user already saw their
     * cancellation succeed at the SA level, so we don't want a Zoom-side
     * hiccup to surface as an error to them.
     */
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

    /**
     * Queueable wrapper around cancelZoomMeetingsForSAs so callers (typically
     * @AuraEnabled methods invoked from a guest-user LWC) can enqueue the
     * Zoom delete AFTER their DML commit — the platform forbids HTTP callouts
     * in the same transaction as pending DML, and the cancellation always
     * does DML on the SA first.
     */
    public class ZoomCancelQueueable implements Queueable, Database.AllowsCallouts {
        private Set<Id> serviceAppointmentIds;
        public ZoomCancelQueueable(Set<Id> saIds) {
            this.serviceAppointmentIds = saIds;
        }
        public void execute(QueueableContext ctx) {
            ZoomMeetingManager.cancelZoomMeetingsForSAs(serviceAppointmentIds);
        }
    }

    // =========================================================================
    //  VALIDATION
    // =========================================================================
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

    // =========================================================================
    //  ICS + EMAIL
    // =========================================================================
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

    /**
     * Same as buildIcs but with an optional override for the ORGANIZER's
     * mailto address. The CN parameter (display name) still uses the ES's
     * name — only the underlying email changes. Used for the host's own
     * .ics so the recipient (ES) doesn't match ORGANIZER's email and Gmail
     * processes the invite as an attendee invitation (auto-add behaviour)
     * instead of "look up event by UID in your own calendar" → "Unable to
     * load event" / manual "Add to Calendar" click.
     */
    private static String buildIcs(
        ServiceAppointment sa, MeetingContext ctx,
        String uid, Integer sequence, String method,
        String joinUrl, String meetingIdForDescription, String zoomInvitationText,
        Map<Id, List<Contact>> parentsByAcct,
        String organizerEmailOverride
    ) {
        // Calendar event title is always "{Student Name} - Zenith Meeting",
        // regardless of who books (student, parent, or staff).
        String studentName = (sa.Contact != null && String.isNotBlank(sa.Contact.Name))
                             ? sa.Contact.Name
                             : (String.isNotBlank(ctx.attendeeName) ? ctx.attendeeName : 'Student');
        String summary = studentName + ' - Zenith Meeting';

        String hostName = (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Name))
                          ? ctx.host.Name : ORG_SENDER_NAME;

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
        // ORGANIZER's display name (CN) is always the ES / Sub-ES / role user
        // — same person whose Zoom account hosts the meeting. The mailto can
        // be overridden by the caller (host's own copy uses the org-wide
        // address so Gmail doesn't trip its organizer-recipient lookup) and
        // otherwise defaults to the host's email.
        ici.organizerName  = (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Name))
                             ? ctx.host.Name : ORG_SENDER_NAME;
        if (String.isNotBlank(organizerEmailOverride)) {
            ici.organizerEmail = organizerEmailOverride;
        } else {
            ici.organizerEmail = (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Email))
                                 ? ctx.host.Email : ORG_SENDER_ADDRESS;
        }
        // SENT-BY only when ORGANIZER's email differs from the SMTP sender
        // (info@...). When they match, SENT-BY is redundant noise.
        if (!ici.organizerEmail.equalsIgnoreCase(ORG_SENDER_ADDRESS)) {
            ici.organizerSentByEmail = ORG_SENDER_ADDRESS;
        }

        ici.primaryAttendee = new ZoomIcsBuilder.Attendee(
            ctx.attendeeName, ctx.attendeeEmail, 'REQ-PARTICIPANT'
        );

        // Mirror the email CC list as ICS ATTENDEE entries so the invite
        // lands on parents' / host's calendars (Gmail and Outlook only
        // auto-add an event when the recipient appears as an ATTENDEE).
        ici.ccAttendees = buildCcAttendees(sa, ctx, parentsByAcct);

        return ZoomIcsBuilder.build(ici);
    }

    /**
     * Build the .ics ATTENDEE list mirroring the email CC list:
     *   - verified parents on the student's account
     *   - the resolved host (ES / substitute / role user)
     * The student is the primaryAttendee and is excluded here.
     */
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
                // The host is also the ORGANIZER. Mark them as CHAIR / ACCEPTED
                // so Gmail and Outlook recognise them as the meeting organizer
                // and add the event straight to their calendar — having the
                // same person as ORGANIZER plus an unaccepted REQ-PARTICIPANT
                // ATTENDEE is contradictory and clients silently drop the
                // event for the organizer in that case.
                out.add(new ZoomIcsBuilder.Attendee(
                    String.isNotBlank(ctx.host.Name) ? ctx.host.Name : ctx.host.Email,
                    ctx.host.Email, 'CHAIR', 'ACCEPTED', false
                ));
            }
        }
        return out;
    }

    /**
     * Build the SendInput for this SA and add it to the transaction-wide
     * email batch instead of sending inline. The actual Messaging.sendEmail
     * call happens once per transaction in deliverEmailBatch() — this keeps
     * us safely under the 10-invocations-per-transaction email governor
     * limit regardless of how many SAs the flow batches in.
     */
    private static void queueInvite(
        ZoomMeetingEmailService.InviteType inviteType,
        ServiceAppointment sa, MeetingContext ctx,
        Map<Id, List<Contact>> parentsByAcct,
        Id orgWideId, String ics, String zoomInvitationText,
        OutputWrapper out,
        List<ZoomMeetingEmailService.SendInput> emailBatch,
        List<OutputWrapper> emailOwners
    ) {
        ZoomMeetingEmailService.SendInput sin = new ZoomMeetingEmailService.SendInput();
        sin.inviteType = inviteType;
        sin.icsContent = ics;
        sin.toEmail    = ctx.attendeeEmail;
        sin.ccEmails   = buildCcList(sa, ctx, parentsByAcct);
        sin.orgWideEmailId = orgWideId;
        sin.relatedWhatId  = sa.Id;
        sin.targetObjectId = sa.ContactId;
        sin.logEmailOnSend = (sa.ContactId != null);

        // CREATE uses the "Zenith Meeting Scheduled" lightning template
        // and RESCHEDULE uses the "Meeting Rescheduled Email Template"
        // (Classic, source-controlled at email/Scheduling_Templates/) so
        // copy edits live in Setup. CANCELLATION still falls back to the
        // in-Apex copy here as a safety net — the live cancel flow drives
        // its own per-status templates via ZoomMeetingCancelEmailAction.
        if (inviteType == ZoomMeetingEmailService.InviteType.NEW_BOOKING
                && sa.ContactId != null) {
            sin.templateId = SCHEDULED_EMAIL_TEMPLATE_ID;
        } else if (inviteType == ZoomMeetingEmailService.InviteType.RESCHEDULE
                && sa.ContactId != null) {
            sin.templateId = RESCHEDULED_EMAIL_TEMPLATE_ID;
        } else {
            sin.subject   = buildSubject(inviteType, sa, ctx);
            sin.htmlBody  = buildHtmlBody(inviteType, sa, ctx, zoomInvitationText);
            sin.plainBody = buildPlainBody(inviteType, sa, ctx, zoomInvitationText);
        }

        emailBatch.add(sin);
        emailOwners.add(out);
    }

    /**
     * Audience per requirement:
     *   TO  = Student (ctx.attendeeEmail, handled upstream in sendInvite)
     *   CC  = Verified parents on the student's Account  +  the resolved role
     *         user (ES / active Substitute ES / PD / AC / FSS — same person
     *         who organises and hosts the Zoom meeting).
     * No cross-role CCs, no Lead Parent 1/2 emails, no generic ORG address.
     */
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

    // =========================================================================
    //  EMAIL COPY — mirrors the "Zenith Meeting Scheduled" lightning template
    //  (Id 00XQU00000ARwzs) so there is a single branded email on every
    //  create / reschedule / cancel, with the .ics attached for calendaring.
    // =========================================================================
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

    private static String buildSubject(
        ZoomMeetingEmailService.InviteType t, ServiceAppointment sa, MeetingContext ctx
    ) {
        String studentName = studentFullName(sa, ctx);
        String hostName    = (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Name))
                             ? ctx.host.Name : ORG_SENDER_NAME;
        String dateLabel   = scheduledDateLabel(sa, ctx);

        if (t == ZoomMeetingEmailService.InviteType.CANCELLATION) {
            return 'Zenith Meeting Cancelled: ' + studentName + ' with ' + hostName
                 + (String.isBlank(dateLabel) ? '' : ' on ' + dateLabel);
        }
        if (t == ZoomMeetingEmailService.InviteType.RESCHEDULE) {
            return 'Zenith Meeting Updated: ' + studentName + ' with ' + hostName
                 + (String.isBlank(dateLabel) ? '' : ' on ' + dateLabel);
        }
        return 'Zenith Meeting Scheduled: ' + studentName + ' with ' + hostName
             + (String.isBlank(dateLabel) ? '' : ' on ' + dateLabel);
    }

    private static String buildHtmlBody(
        ZoomMeetingEmailService.InviteType t, ServiceAppointment sa,
        MeetingContext ctx, String zoomInvitationText
    ) {
        String firstName = String.escapeSingleQuotes(studentFirstName(sa, ctx));
        String hostName  = String.escapeSingleQuotes(
            (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Name))
                ? ctx.host.Name : ORG_SENDER_NAME);
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

    private static String buildPlainBody(
        ZoomMeetingEmailService.InviteType t, ServiceAppointment sa,
        MeetingContext ctx, String zoomInvitationText
    ) {
        String firstName = studentFirstName(sa, ctx);
        String hostName  = (ctx != null && ctx.host != null && String.isNotBlank(ctx.host.Name))
                           ? ctx.host.Name : ORG_SENDER_NAME;
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

    // =========================================================================
    //  FORMATTING HELPERS
    // =========================================================================
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

    // =========================================================================
    //  ICS LIFECYCLE HELPERS
    // =========================================================================
    private static String computeIcsUid(ServiceAppointment sa) {
        return 'sa-' + String.valueOf(sa.Id) + ICS_UID_DOMAIN;
    }

    /**
     * Derive a strictly-increasing SEQUENCE value from the SA's own audit
     * timestamps — no dedicated storage field needed. Returns seconds
     * elapsed between SA creation and its last modification. Every write
     * to the SA bumps SystemModstamp, so the sequence monotonically
     * increases across create → reschedule → cancel, which is what
     * calendar clients require to apply (not drop) successive updates.
     */
    private static Integer deriveSequence(ServiceAppointment sa) {
        if (sa == null || sa.SystemModstamp == null || sa.CreatedDate == null) return 0;
        Long deltaMs = sa.SystemModstamp.getTime() - sa.CreatedDate.getTime();
        if (deltaMs <= 0) return 0;
        return (Integer) (deltaMs / 1000L);
    }

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

    // =========================================================================
    //  SOQL
    // =========================================================================
    private static Map<Id, ServiceAppointment> loadAppointments(Set<Id> saIds) {
        // Built dynamically so optional custom fields (Guest_Emails__c) are
        // only requested in orgs where they exist — keeps the class
        // deployable to sandboxes that haven't created the field yet.
        String soql =
            'SELECT Id, Subject, SchedStartTime, SchedEndTime, Status, '
          + '       Meeting_Type__c, Email, Phone, '
          + '       Zoom_Meeting_ID__c, Zoom_Link__c, Zoom_Join_URL__c, Zoom_Start_URL__c, '
          + '       CreatedDate, SystemModstamp, '
          + '       ContactId, '
          + '       Contact.Id, Contact.Name, Contact.Email, Contact.AccountId, '
          + '       Contact.Counselor__c, '
          + '       Contact.Counselor__r.Name, Contact.Counselor__r.Email, Contact.Counselor__r.TimeZoneSidKey, '
          + '       Contact.Substitute_Counselor__c, '
          + '       Contact.Substitute_Counselor__r.Name, Contact.Substitute_Counselor__r.Email, Contact.Substitute_Counselor__r.TimeZoneSidKey, '
          + '       Contact.Program_Director__c, '
          + '       Contact.Program_Director__r.Name, Contact.Program_Director__r.Email, Contact.Program_Director__r.TimeZoneSidKey, '
          + '       Contact.Family_Success_Specialist__c, '
          + '       Contact.Family_Success_Specialist__r.Name, Contact.Family_Success_Specialist__r.Email, Contact.Family_Success_Specialist__r.TimeZoneSidKey, '
          + '       Contact.IC_admissions_counselor__c, '
          + '       Contact.IC_admissions_counselor__r.Name, Contact.IC_admissions_counselor__r.Email, Contact.IC_admissions_counselor__r.TimeZoneSidKey, '
          + '       Educational_Strategist__c, '
          + '       Educational_Strategist__r.Name, Educational_Strategist__r.Email, Educational_Strategist__r.TimeZoneSidKey, '
          + '       Admission_Counselor__c, '
          + '       Admission_Counselor__r.Name, Admission_Counselor__r.Email, Admission_Counselor__r.TimeZoneSidKey, '
          + '       Program_Director__c, '
          + '       Program_Director__r.Name, Program_Director__r.Email, Program_Director__r.TimeZoneSidKey, '
          + '       Family_Success_Specialist__c, '
          + '       Family_Success_Specialist__r.Name, Family_Success_Specialist__r.Email, Family_Success_Specialist__r.TimeZoneSidKey, '
          + '       ParentRecordId, ParentRecordType, '
          + '       OwnerId'
          + (hasGuestEmailsField() ? ', Guest_Emails__c ' : ' ')
          + 'FROM ServiceAppointment WHERE Id IN :saIds';
        return new Map<Id, ServiceAppointment>(
            (List<ServiceAppointment>) Database.query(soql)
        );
    }

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
                   Assigned_Admission_Counsellor__r.Email,
                   Assigned_Admission_Counsellor__r.TimeZoneSidKey,
                   Assigned_PD__c,
                   Assigned_PD__r.Name,
                   Assigned_PD__r.Email,
                   Assigned_PD__r.TimeZoneSidKey
            FROM Lead
            WHERE Id IN :leadIds
        ]);
    }

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
            SELECT Id, Name, Email, TimeZoneSidKey
            FROM User
            WHERE Id IN :userOwnerIds
        ]);
    }

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