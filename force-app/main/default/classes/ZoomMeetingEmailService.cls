// Sends meeting invite/update/cancellation emails with the .ics calendar attached using the correct MIME type.
public class ZoomMeetingEmailService {

    public enum InviteType { NEW_BOOKING, RESCHEDULE, CANCELLATION }

    public class SendResult {
        public Boolean success;
        public String  errorMessage;
    }

    public class SendInput {
        public InviteType inviteType;
        public String icsContent;
        public String toEmail;
        public List<String> ccEmails;
        public String orgWideEmailId;
        public String subject;
        public String htmlBody;
        public String plainBody;
        public Id templateId;
        public Id relatedWhatId;
        public Id targetObjectId;
        public Boolean logEmailOnSend;
        // Optional. When set, sendBulk re-stamps the created EmailMessage.RelatedToId to this Id
        // (typically the Opportunity) so the email lands on the Opportunity's activity timeline.
        // relatedWhatId stays as the SA so the Lightning template's SA merge fields still resolve.
        public Id activityRelatedToId;
        // Optional override for the .ics Content-Type method parameter ('PUBLISH', 'REQUEST',
        // 'CANCEL'). Used for the host-side email where the ICS body is METHOD:PUBLISH so Gmail
        // accepts it even though host == ORGANIZER == recipient. When null, the method is derived
        // from inviteType (REQUEST for NEW_BOOKING/RESCHEDULE, CANCEL for CANCELLATION).
        public String icsMethod;
    }

    // Sends a batch of calendar-invite emails in a single Messaging.sendEmail invocation.
    public static List<SendResult> sendBulk(List<SendInput> inputs) {
        List<SendResult> results = new List<SendResult>();
        if (inputs == null || inputs.isEmpty()) return results;

        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
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

        DateTime sendStartTime = DateTime.now();

        Messaging.SendEmailResult[] sendResults;
        try {
            sendResults = Messaging.sendEmail(messages, false);
        } catch (Exception e) {
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

        // Collect successful (toAddress → activityRelatedToId) pairs so we can re-stamp the
        // resulting EmailMessage.RelatedToId onto the Opportunity (etc.). relatedWhatId stayed
        // on the SA so Lightning template merge fields render correctly; this post-process is
        // what makes the email show up on the Opportunity activity timeline.
        Map<String, Id> activityRelatedByToAddr = new Map<String, Id>();

        Integer sentIdx = 0;
        for (Integer i = 0; i < inputs.size(); i++) {
            if (!sendable[i]) continue;
            Messaging.SendEmailResult r = sendResults[sentIdx++];
            if (r.isSuccess()) {
                results[i].success = true;
                SendInput inp = inputs[i];
                if (inp.activityRelatedToId != null && String.isNotBlank(inp.toEmail)) {
                    activityRelatedByToAddr.put(inp.toEmail.toLowerCase().trim(), inp.activityRelatedToId);
                }
            } else {
                Messaging.SendEmailError[] errs = r.getErrors();
                results[i].errorMessage = (errs != null && errs.size() > 0)
                    ? errs[0].getStatusCode() + ': ' + errs[0].getMessage()
                    : 'Unknown email error';
            }
        }

        if (!activityRelatedByToAddr.isEmpty()) {
            try {
                Id currentUserId = UserInfo.getUserId();
                List<EmailMessage> recents = [
                    SELECT Id, ToAddress, RelatedToId
                    FROM EmailMessage
                    WHERE CreatedDate >= :sendStartTime
                    AND CreatedById = :currentUserId
                    LIMIT 200
                ];
                List<EmailMessage> toUpdate = new List<EmailMessage>();
                for (EmailMessage em : recents) {
                    if (em.ToAddress == null) continue;
                    Id target = activityRelatedByToAddr.get(em.ToAddress.toLowerCase().trim());
                    if (target != null && em.RelatedToId != target) {
                        em.RelatedToId = target;
                        toUpdate.add(em);
                    }
                }
                if (!toUpdate.isEmpty()) {
                    Database.update(toUpdate, false);
                }
            } catch (Exception emEx) {
                System.debug(LoggingLevel.WARN,
                    'EmailMessage RelatedToId post-process failed (non-fatal): ' + emEx.getMessage());
            }
        }

        return results;
    }

    // Single-message send convenience wrapper that delegates to sendBulk.
    public static SendResult send(SendInput inp) {
        List<SendResult> out = sendBulk(new List<SendInput>{ inp });
        return out.isEmpty() ? new SendResult() : out[0];
    }

    // Builds (but does not send) a Messaging.SingleEmailMessage from a SendInput.
    // icsContent is optional — when blank, no .ics attachment is added. This supports the
    // host-notification path where the host receives the same template but no calendar invite
    // (their calendar is populated via the Salesforce Event → EAC sync, with the host as organizer).
    private static Messaging.SingleEmailMessage buildMessage(SendInput inp) {
        if (String.isBlank(inp.toEmail)) {
            throw new ZoomEmailException('Primary recipient email is required.');
        }

        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();

        msg.setToAddresses(new List<String>{ inp.toEmail });
        if (inp.ccEmails != null && !inp.ccEmails.isEmpty()) {
            msg.setCcAddresses(dedupAndClean(inp.ccEmails, inp.toEmail));
        }

        if (String.isNotBlank(inp.orgWideEmailId)) {
            msg.setOrgWideEmailAddressId(inp.orgWideEmailId);
        }

        if (inp.targetObjectId != null) {
            msg.setTargetObjectId(inp.targetObjectId);
            msg.setTreatTargetObjectAsRecipient(false);
        }
        Boolean isLeadTarget = inp.targetObjectId != null
            && String.valueOf(inp.targetObjectId).startsWith('00Q');
        Boolean wantsSaveAsActivity = inp.logEmailOnSend == true
            && inp.targetObjectId != null;
        Boolean skipWhatId = isLeadTarget && wantsSaveAsActivity;
        if (inp.relatedWhatId != null && !skipWhatId) {
            msg.setWhatId(inp.relatedWhatId);
        }

        if (inp.templateId != null) {
            renderTemplateOntoMessage(msg, inp);
        } else {
            msg.setSubject(inp.subject);
            if (String.isNotBlank(inp.htmlBody)) {
                String body = inp.htmlBody;
                if (inp.inviteType == InviteType.RESCHEDULE) {
                    body = wrapWithZenithLetterhead(body);
                }
                msg.setHtmlBody(body);
            }
            if (String.isNotBlank(inp.plainBody)) {
                msg.setPlainTextBody(inp.plainBody);
            }
        }
        try {
            msg.setSaveAsActivity(inp.logEmailOnSend == true && inp.targetObjectId != null);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'setSaveAsActivity threw for targetObjectId=' + inp.targetObjectId
                + ' — disabling activity logging for this message: ' + e.getMessage());
            msg.setSaveAsActivity(false);
        }
        msg.setUseSignature(false);

        // Skip the .ics attachment when icsContent is blank — host-notification path can pass
        // null when EAC is the only desired calendar source. When set, icsMethod overrides the
        // default Content-Type method (used for METHOD:PUBLISH on the host's own .ics so Gmail
        // doesn't trip the "Unable to load event" check for recipient==ORGANIZER).
        if (String.isNotBlank(inp.icsContent)) {
            String icsMethod = String.isNotBlank(inp.icsMethod)
                ? inp.icsMethod.toUpperCase()
                : ((inp.inviteType == InviteType.CANCELLATION) ? 'CANCEL' : 'REQUEST');

            Messaging.EmailFileAttachment ics = new Messaging.EmailFileAttachment();
            ics.setFileName('invite.ics');
            ics.setBody(Blob.valueOf(inp.icsContent));
            ics.setContentType(
                'text/calendar; charset=UTF-8; method=' + icsMethod + '; name="invite.ics"'
            );
            ics.setInline(false);

            msg.setFileAttachments(new List<Messaging.EmailFileAttachment>{ ics });
        }
        return msg;
    }

    // Renders a stored Lightning Email Template onto the message.
    // If rendering fails, fall back to the Apex-built subject/htmlBody/plainBody on the SendInput
    // — NEVER call msg.setTemplateId() here, because Salesforce silently drops setFileAttachments
    // (the .ics calendar invite) on any message that uses setTemplateId.
    private static void renderTemplateOntoMessage(
        Messaging.SingleEmailMessage msg, SendInput inp
    ) {
        Messaging.SingleEmailMessage rendered;
        try {
            rendered = Messaging.renderStoredEmailTemplate(
                inp.templateId, inp.targetObjectId, inp.relatedWhatId
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'renderStoredEmailTemplate FAILED templateId=' + inp.templateId
                + ' targetObjectId=' + inp.targetObjectId
                + ' relatedWhatId=' + inp.relatedWhatId
                + ' — ' + e.getMessage()
                + ' | using Apex-built fallback body (keeps ICS attachment intact).');
            if (String.isNotBlank(inp.subject))   msg.setSubject(inp.subject);
            if (String.isNotBlank(inp.htmlBody))  msg.setHtmlBody(inp.htmlBody);
            if (String.isNotBlank(inp.plainBody)) msg.setPlainTextBody(inp.plainBody);
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
        }
        return cachedZenithLetterhead;
    }

    // Removes the TO email from CCs, plus blanks and duplicates.
    private static List<String> dedupAndClean(List<String> ccEmails, String toEmail) {
        Set<String> seen = new Set<String>();
        List<String> out = new List<String>();
        String toLower = (toEmail == null) ? '' : toEmail.toLowerCase().trim();
        for (String e : ccEmails) {
            if (String.isBlank(e)) continue;
            String norm = e.toLowerCase().trim();
            if (norm == toLower) continue;
            if (seen.contains(norm)) continue;
            seen.add(norm);
            out.add(e.trim());
        }
        return out;
    }

    public class ZoomEmailException extends Exception {}

    // Input wrapper for the flow-callable email send.
    public class FlowSendInput {
        @InvocableVariable(
            required=true
            label='Service Appointment Id'
            description='SA whose meeting confirmation (with .ics) should be emailed.')
        public Id serviceAppointmentId;
    }

    // Flow-invocable: sends the Zenith Meeting Scheduled template plus .ics invite for the given Service Appointments.
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
