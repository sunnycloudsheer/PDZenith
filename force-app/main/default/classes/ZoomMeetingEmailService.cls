/**
 * @File Name          : ZoomMeetingEmailService.cls
 * @Description        : Sends the meeting invite / update / cancellation email
 *                       with the .ics calendar file attached using the correct
 *                       MIME type (text/calendar; method=REQUEST|CANCEL).
 *
 *                       IMPORTANT — Content-Type handling
 *                       -------------------------------------------------------
 *                       Outlook, Google Calendar and Apple Calendar detect a
 *                       calendar invite by looking at the attachment's
 *                       Content-Type. Setting it to:
 *                           text/calendar; method=REQUEST; charset=UTF-8
 *                       causes Gmail to render the native "Yes/No/Maybe"
 *                       interactive block and Outlook to treat it as a
 *                       real calendar invite (Accept / Decline buttons)
 *                       rather than a plain file attachment.
 *
 *                       On CANCEL we switch to "method=CANCEL" which
 *                       instructs the client to REMOVE the existing event.
 *
 * @Author             : Amit Yadav
 * @Created On         : April 2026
 */
public class ZoomMeetingEmailService {

    public enum InviteType { NEW_BOOKING, RESCHEDULE, CANCELLATION }

    public class SendResult {
        public Boolean success;
        public String  errorMessage;
    }

    public class SendInput {
        public InviteType inviteType;
        public String icsContent;         // Output of ZoomIcsBuilder.build(...)
        public String toEmail;            // Primary recipient (family)
        public List<String> ccEmails;     // Parents / counselors
        public String orgWideEmailId;     // OrgWideEmailAddress Id (optional)
        public String subject;
        public String htmlBody;
        public String plainBody;
        /**
         * EmailTemplate Id. When set, the template renders the subject +
         * body (merge fields resolved via targetObjectId / relatedWhatId)
         * and subject / htmlBody / plainBody on this input are ignored.
         * Use for CREATE to drive the Zenith Meeting Scheduled lightning
         * template directly, so Setup-side edits propagate without a deploy.
         */
        public Id templateId;
        public Id relatedWhatId;          // ServiceAppointment Id for email logging
        public Id targetObjectId;         // Contact Id for email logging
        /**
         * When true the email is logged as an Activity on the record.
         * Requires targetObjectId to be a valid Lead/Contact/User Id.
         */
        public Boolean logEmailOnSend;
    }

    /**
     * Send a batch of calendar-invite emails in ONE Messaging.sendEmail
     * invocation. Bulk-safe: the 10-invocation-per-transaction email limit
     * is per call to Messaging.sendEmail, not per message, so batching lets
     * us deliver unlimited messages from a single invocable call.
     *
     * Order of results matches order of inputs. An input that fails
     * validation (blank TO / blank ICS) gets a failure result at the
     * corresponding position — the rest of the batch still sends.
     */
    public static List<SendResult> sendBulk(List<SendInput> inputs) {
        List<SendResult> results = new List<SendResult>();
        if (inputs == null || inputs.isEmpty()) return results;

        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        // Parallel list: sendable[i] == true  → messages[?]  maps back to inputs[i]
        // If sendable[i] == false, we already recorded the failure in results
        // and skipped adding to messages.
        List<Boolean> sendable = new List<Boolean>();

        for (SendInput inp : inputs) {
            SendResult slot = new SendResult();
            slot.success = false;
            results.add(slot);

            try {
                Messaging.SingleEmailMessage msg = buildMessage(inp);
                messages.add(msg);
                sendable.add(true);
            } catch (Exception e) {
                slot.errorMessage = e.getMessage();
                sendable.add(false);
            }
        }

        if (messages.isEmpty()) return results;

        Messaging.SendEmailResult[] sendResults;
        try {
            sendResults = Messaging.sendEmail(messages, false);
        } catch (Exception e) {
            // Whole batch threw — mark every sendable slot as failed and
            // log to the debug log so the failure is visible (it was
            // previously only attached to in-memory result objects that
            // the flow caller silently discards).
            System.debug(LoggingLevel.ERROR,
                'Messaging.sendEmail BATCH FAILURE — ' + messages.size()
                + ' message(s) — ' + e.getTypeName() + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            for (Integer i = 0; i < sendable.size(); i++) {
                if (sendable[i]) {
                    results[i].success = false;
                    results[i].errorMessage = e.getMessage();
                }
            }
            return results;
        }

        // Re-align sendResults (only has entries for sendable messages) with
        // the original inputs/results index space.
        Integer sentIdx = 0;
        for (Integer i = 0; i < inputs.size(); i++) {
            if (!sendable[i]) continue;
            Messaging.SendEmailResult r = sendResults[sentIdx++];
            if (r.isSuccess()) {
                results[i].success = true;
            } else {
                Messaging.SendEmailError[] errs = r.getErrors();
                results[i].errorMessage = (errs != null && errs.size() > 0)
                    ? errs[0].getStatusCode() + ': ' + errs[0].getMessage()
                    : 'Unknown email error';
            }
        }
        return results;
    }

    /**
     * Single-message send. Delegates to sendBulk() so behaviour is identical
     * whether called once or in a batch. Retained for backwards compatibility
     * and simpler call sites where the caller has exactly one input.
     */
    public static SendResult send(SendInput inp) {
        List<SendResult> out = sendBulk(new List<SendInput>{ inp });
        return out.isEmpty() ? new SendResult() : out[0];
    }

    /**
     * Build (but do not send) a Messaging.SingleEmailMessage from a SendInput.
     * Throws ZoomEmailException on missing required fields.
     */
    private static Messaging.SingleEmailMessage buildMessage(SendInput inp) {
        if (String.isBlank(inp.toEmail)) {
            throw new ZoomEmailException('Primary recipient email is required.');
        }
        if (String.isBlank(inp.icsContent)) {
            throw new ZoomEmailException('ICS content is required.');
        }

        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();

        // --- recipients ---
        msg.setToAddresses(new List<String>{ inp.toEmail });
        if (inp.ccEmails != null && !inp.ccEmails.isEmpty()) {
            msg.setCcAddresses(dedupAndClean(inp.ccEmails, inp.toEmail));
        }

        // --- sender ---
        if (String.isNotBlank(inp.orgWideEmailId)) {
            msg.setOrgWideEmailAddressId(inp.orgWideEmailId);
        }

        // --- targeting (must be set BEFORE template merge so the
        //     template resolves Recipient / Related fields correctly) ---
        if (inp.targetObjectId != null) {
            msg.setTargetObjectId(inp.targetObjectId);
            msg.setTreatTargetObjectAsRecipient(false);
        }
        if (inp.relatedWhatId != null) {
            msg.setWhatId(inp.relatedWhatId);
        }

        // --- subject / body ---
        if (inp.templateId != null) {
            // Render the Lightning Email Template explicitly. We can't use
            // setTemplateId() because Salesforce won't merge the recipient's
            // {{{ServiceAppointment.Zoom_Link__c}}} from the DB unless the
            // record is already saved (Fix #1 handles that). Note:
            // renderStoredEmailTemplate ALREADY wraps Lightning templates
            // with their Enhanced Letterhead — do NOT re-prepend it here
            // (double-letterhead was the original CREATE rendering bug).
            renderTemplateOntoMessage(msg, inp);
        } else {
            msg.setSubject(inp.subject);
            if (String.isNotBlank(inp.htmlBody)) {
                String body = inp.htmlBody;
                // RESCHEDULE-with-ContactId uses the Lightning "Meeting
                // Rescheduled Email Template" (rendered via the templateId
                // path above, with the letterhead baked in). This branch
                // only runs for the lead-based fallback (no ContactId) —
                // wrap the in-Apex copy with the Setup-side Zenith Prep
                // Lightning Letterhead so the brand chrome matches.
                if (inp.inviteType == InviteType.RESCHEDULE) {
                    body = wrapWithZenithLetterhead(body);
                }
                msg.setHtmlBody(body);
            }
            if (String.isNotBlank(inp.plainBody)) {
                msg.setPlainTextBody(inp.plainBody);
            }
        }
        // setSaveAsActivity(true) requires a valid targetObjectId on a record
        // type that supports activities (Lead, Contact, User). If the Lead has
        // already been converted between booking and the Zoom hydration, this
        // call throws and silently aborts the entire batch. Wrap it so the
        // worst case is "email sent but not logged as an Activity".
        try {
            msg.setSaveAsActivity(inp.logEmailOnSend == true && inp.targetObjectId != null);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'setSaveAsActivity threw for targetObjectId=' + inp.targetObjectId
                + ' — disabling activity logging for this message: ' + e.getMessage());
            msg.setSaveAsActivity(false);
        }
        msg.setUseSignature(false);

        // --- .ics attachment with correct content-type ---
        String icsMethod = (inp.inviteType == InviteType.CANCELLATION) ? 'CANCEL' : 'REQUEST';

        Messaging.EmailFileAttachment ics = new Messaging.EmailFileAttachment();
        ics.setFileName('invite.ics');
        ics.setBody(Blob.valueOf(inp.icsContent));
        ics.setContentType(
            'text/calendar; charset=UTF-8; method=' + icsMethod + '; name="invite.ics"'
        );
        ics.setInline(false);

        msg.setFileAttachments(new List<Messaging.EmailFileAttachment>{ ics });
        return msg;
    }

    private static void renderTemplateOntoMessage(
        Messaging.SingleEmailMessage msg, SendInput inp
    ) {
        Messaging.SingleEmailMessage rendered;
        try {
            rendered = Messaging.renderStoredEmailTemplate(
                inp.templateId, inp.targetObjectId, inp.relatedWhatId
            );
        } catch (Exception e) {
            // Render failed — fall back to the template-driven send so the
            // email still goes out (without recipient-aware merge resolution).
            // Logging the failure so silent template misconfiguration (wrong
            // template Id, converted Lead, missing merge field permissions)
            // is visible in debug logs instead of vanishing.
            System.debug(LoggingLevel.WARN,
                'renderStoredEmailTemplate FAILED templateId=' + inp.templateId
                + ' targetObjectId=' + inp.targetObjectId
                + ' relatedWhatId=' + inp.relatedWhatId
                + ' — ' + e.getMessage()
                + ' | falling back to setTemplateId()');
            msg.setTemplateId(inp.templateId);
            return;
        }

        msg.setSubject(rendered.getSubject());
        if (String.isNotBlank(rendered.getHtmlBody())) {
            msg.setHtmlBody(rendered.getHtmlBody());
        }
        if (String.isNotBlank(rendered.getPlainTextBody())) {
            msg.setPlainTextBody(rendered.getPlainTextBody());
        }
    }

    // Cache the "Zenith Prep Lightning Letterhead" lookup across the
    // transaction — RESCHEDULE batches reuse the same wrap, no point
    // re-querying per email.
    private static EnhancedLetterhead cachedZenithLetterhead;
    private static Boolean zenithLetterheadResolved = false;

    @TestVisible
    private static String wrapWithZenithLetterhead(String body) {
        if (String.isBlank(body)) return body;
        EnhancedLetterhead lh = resolveZenithLetterhead();
        if (lh == null) return body;
        String header = String.isNotBlank(lh.LetterheadHeader) ? lh.LetterheadHeader : '';
        String footer = String.isNotBlank(lh.LetterheadFooter) ? lh.LetterheadFooter : '';
        return header + body + footer;
    }

    private static EnhancedLetterhead resolveZenithLetterhead() {
        if (zenithLetterheadResolved) return cachedZenithLetterhead;
        zenithLetterheadResolved = true;
        try {
            List<EnhancedLetterhead> lhs = [
                SELECT LetterheadHeader, LetterheadFooter
                FROM EnhancedLetterhead
                WHERE Name = 'Zenith Prep Lightning Letterhead'
                LIMIT 1
            ];
            if (!lhs.isEmpty()) cachedZenithLetterhead = lhs[0];
        } catch (Exception e) {
            // Letterhead not accessible — leave the body unwrapped rather
            // than failing the email send.
        }
        return cachedZenithLetterhead;
    }

    /** Remove the TO email from CCs, remove blanks and duplicates. */
    private static List<String> dedupAndClean(List<String> ccEmails, String toEmail) {
        Set<String> seen = new Set<String>();
        List<String> out = new List<String>();
        String toLower = (toEmail == null) ? '' : toEmail.toLowerCase().trim();
        for (String e : ccEmails) {
            if (String.isBlank(e)) continue;
            String norm = e.toLowerCase().trim();
            if (norm == toLower) continue;   // already a TO
            if (seen.contains(norm)) continue;
            seen.add(norm);
            out.add(e.trim());
        }
        return out;
    }

    public class ZoomEmailException extends Exception {}

    // =========================================================================
    //  FLOW INVOCABLE
    // =========================================================================
    /**
     * Input wrapper for the flow-callable email send. Salesforce's flow
     * Apex-action picker reads @InvocableVariable fields off this class.
     */
    public class FlowSendInput {
        @InvocableVariable(
            required=true
            label='Service Appointment Id'
            description='SA whose meeting confirmation (with .ics) should be emailed.')
        public Id serviceAppointmentId;
    }

    /**
     * Send the Zenith Meeting Scheduled lightning template + .ics calendar
     * invite to student / verified parents / assigned ES. Designed to be
     * called from Meeting_After_RTF in place of the emailSimple action so
     * the flow can attach the .ics that emailSimple can't.
     */
    @InvocableMethod(
        label='Send Zenith Meeting Scheduled Email With ICS'
        description='Sends the Zenith Meeting Scheduled lightning template plus the calendar (.ics) invite to student, verified parents, and the assigned Educational Strategist so the event lands on every recipient\'s calendar.'
        callout=false)
    public static void sendInviteFromFlow(List<FlowSendInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return;
        Set<Id> saIds = new Set<Id>();
        for (FlowSendInput i : inputs) {
            if (i != null && i.serviceAppointmentId != null) saIds.add(i.serviceAppointmentId);
        }
        if (!saIds.isEmpty()) ZoomMeetingManager.sendInvitesForSavedAppointments(saIds);
    }
}