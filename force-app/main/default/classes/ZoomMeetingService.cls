// Scheduled-meeting + .ICS calendar invite service (NEW_BOOKING / RESCHEDULE / CANCELLATION) over Named Credential 'Zoom_App'.
public without sharing class ZoomMeetingService {

    public enum InviteAction { NEW_BOOKING, RESCHEDULE, CANCELLATION }

    public class MeetingConfig {
        @InvocableVariable public String       topic;
        @InvocableVariable public DateTime     startTime;
        @InvocableVariable public Integer      duration;
        @InvocableVariable public List<String> recipientEmails;
        @InvocableVariable public String       agenda;
        @InvocableVariable public Boolean      muteParticipantsOnEntry;
        @InvocableVariable public String       password;
        @InvocableVariable public String       existingUid;
        @InvocableVariable public Integer      sequenceNumber;
        @InvocableVariable public String       action;
        @InvocableVariable public String       organizerEmail;
        @InvocableVariable public String       organizerName;
        @InvocableVariable public String       familyTimezone;
        public Boolean enableWaitingRoom;

        public MeetingConfig() {
            this.enableWaitingRoom       = false;
            this.muteParticipantsOnEntry = true;
            this.duration                = 60;
            this.sequenceNumber          = 0;
            this.action                  = 'NEW_BOOKING';
            this.familyTimezone          = 'UTC';
        }
    }

    public class MeetingResponse {
        @InvocableVariable public Boolean  success;
        @InvocableVariable public String   meetingId;
        @InvocableVariable public String   joinUrl;
        @InvocableVariable public String   startUrl;
        @InvocableVariable public String   password;
        @InvocableVariable public String   errorMessage;
        @InvocableVariable public String   icsUid;
        @InvocableVariable public String   contentDocumentId;

        public MeetingResponse() { this.success = false; }
    }

    // Invocable entry point — creates / patches / cancels a Zoom meeting and dispatches the branded email + .ics.
    @InvocableMethod(label = 'Create Zoom Meeting' callout = true)
    public static List<MeetingResponse> createMeeting(List<MeetingConfig> configs) {
        MeetingConfig   cfg  = configs[0];
        MeetingResponse resp = new MeetingResponse();

        try {
            if (String.isBlank(cfg.topic)) {
                resp.errorMessage = 'Topic is required';
                return new List<MeetingResponse>{ resp };
            }

            String actionStr = (cfg.action != null) ? cfg.action : 'NEW_BOOKING';

            String icsUid = String.isNotBlank(cfg.existingUid)
                ? cfg.existingUid
                : generateUniqueId();
            resp.icsUid = icsUid;

            if (actionStr == 'CANCELLATION') {
                resp.success = true;
                if (cfg.recipientEmails != null && !cfg.recipientEmails.isEmpty()) {
                    sendCancellationEmail(cfg, icsUid);
                }
                return new List<MeetingResponse>{ resp };
            }

            String encodedHost = EncodingUtil.urlEncode(
                String.isNotBlank(cfg.organizerEmail) ? cfg.organizerEmail : 'me',
                'UTF-8'
            );

            HttpRequest req = new HttpRequest();

            if (actionStr == 'RESCHEDULE' && String.isNotBlank(cfg.existingUid)) {
                req.setEndpoint('callout:Zoom_App/meetings/' + cfg.existingUid);
                req.setMethod('PATCH');
            } else {
                req.setEndpoint('callout:Zoom_App/users/' + encodedHost + '/meetings');
                req.setMethod('POST');
            }

            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', '*/*');
            req.setBody(JSON.serialize(buildZoomBody(cfg)));

            HttpResponse res = new Http().send(req);
            System.debug('Zoom Status: ' + res.getStatusCode());
            System.debug('Zoom Body:   ' + res.getBody());

            if (res.getStatusCode() == 201 || res.getStatusCode() == 204) {
                resp.success = true;

                if (res.getStatusCode() == 201) {
                    Map<String, Object> data =
                        (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

                    resp.meetingId = String.valueOf(data.get('id'));
                    resp.joinUrl   = (String) data.get('join_url');
                    resp.startUrl  = (String) data.get('start_url');
                    resp.password  = (String) data.get('password');
                    resp.icsUid    = icsUid;
                    System.debug('Meeting Created — ID: ' + resp.meetingId);

                } else {
                    resp.meetingId = cfg.existingUid;
                    System.debug('Meeting Updated (PATCH) — ID: ' + resp.meetingId);
                }

                if (cfg.recipientEmails != null && !cfg.recipientEmails.isEmpty()) {
                    String icsContent = generateNewBookingIcs(cfg, icsUid, resp.joinUrl, actionStr);

                    String fileName = String.isNotBlank(cfg.topic)
                        ? cfg.topic.replaceAll('[^a-zA-Z0-9 _-]', '')
                        : 'ZoomMeeting';
                    resp.contentDocumentId = saveIcsAsContentVersion(
                        icsContent,
                        fileName,
                        null
                    );

                    sendMeetingEmail(cfg, resp, icsUid, icsContent, actionStr);
                }

            } else {
                resp.errorMessage = 'Zoom API Error: ' + res.getStatusCode()
                                  + ' — ' + res.getBody();
                System.debug('Zoom Error: ' + res.getStatusCode() + ' — ' + res.getBody());
            }

        } catch (Exception ex) {
            resp.errorMessage = ex.getMessage();
            System.debug('Exception: ' + ex.getMessage());
            System.debug('Stack:     ' + ex.getStackTraceString());
        }

        return new List<MeetingResponse>{ resp };
    }

    // Sends the branded Zoom invitation email with .ics attachment for NEW_BOOKING / RESCHEDULE.
    private static void sendMeetingEmail(
        MeetingConfig   cfg,
        MeetingResponse resp,
        String          icsUid,
        String          icsContent,
        String          actionStr
    ) {
        try {
            List<Messaging.SingleEmailMessage> emailList =
                new List<Messaging.SingleEmailMessage>();

            for (String emailAddr : cfg.recipientEmails) {
                if (String.isBlank(emailAddr)) continue;

                Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setToAddresses(new List<String>{ emailAddr.trim() });

                String subject = (actionStr == 'RESCHEDULE')
                    ? 'Updated: ' + cfg.topic
                    : 'Invitation: ' + cfg.topic;
                mail.setSubject(subject);

                mail.setHtmlBody(buildMeetingEmailHtml(cfg, resp, actionStr));

                Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
                att.setFileName(cfg.topic + '.ics');
                att.setBody(Blob.valueOf(icsContent));
                att.setContentType('text/calendar; method=REQUEST; charset=UTF-8');
                mail.setFileAttachments(
                    new List<Messaging.EmailFileAttachment>{ att }
                );

                emailList.add(mail);
            }

            if (!emailList.isEmpty()) {
                Messaging.sendEmail(emailList);
                System.debug('Meeting invite email sent to: ' + cfg.recipientEmails);
            }
        } catch (Exception ex) {
            System.debug('sendMeetingEmail Exception: ' + ex.getMessage());
        }
    }

    // Builds the HTML body for the new-booking / reschedule invitation email.
    private static String buildMeetingEmailHtml(
        MeetingConfig   cfg,
        MeetingResponse resp,
        String          actionStr
    ) {
        String timeDisplay = '';
        if (cfg.startTime != null) {
            timeDisplay = cfg.startTime.format('EEEE, MMMM d, yyyy')
                + ' at ' + cfg.startTime.format('h:mm a')
                + ' (' + (String.isNotBlank(cfg.familyTimezone) ? cfg.familyTimezone : 'UTC') + ')';
        }

        String bannerColor  = (actionStr == 'RESCHEDULE') ? '#e67e22' : '#2563eb';
        String bannerIcon   = (actionStr == 'RESCHEDULE') ? '&#128336;' : '&#128197;';
        String bannerTitle  = (actionStr == 'RESCHEDULE') ? 'Meeting Updated' : 'You\'re Invited!';
        String bannerSub    = (actionStr == 'RESCHEDULE')
            ? 'This meeting has been rescheduled'
            : 'Join us for an upcoming Zoom meeting';

        String joinBlock = '';
        if (String.isNotBlank(resp.joinUrl)) {
            joinBlock = '<div style="text-align:center;margin:24px 0">'
                + '<a href="' + resp.joinUrl + '" '
                + 'style="display:inline-block;background:#2563eb;color:#fff;'
                + 'text-decoration:none;padding:14px 32px;border-radius:8px;'
                + 'font-size:16px;font-weight:700;letter-spacing:.3px">'
                + '&#128249;&nbsp; Join Zoom Meeting</a></div>'
                + '<p style="text-align:center;font-size:12px;color:#888;word-break:break-all">'
                + '<a href="' + resp.joinUrl + '" style="color:#888">' + resp.joinUrl + '</a></p>';
        }

        String passwordBlock = '';
        if (String.isNotBlank(resp.password)) {
            passwordBlock = '<p style="font-size:13px;color:#444;margin:6px 0">'
                + '&#128274;&nbsp; <strong>Passcode:</strong> ' + resp.password + '</p>';
        }

        String meetingIdBlock = '';
        if (String.isNotBlank(resp.meetingId)) {
            meetingIdBlock = '<p style="font-size:13px;color:#444;margin:6px 0">'
                + '&#128290;&nbsp; <strong>Meeting ID:</strong> ' + resp.meetingId + '</p>';
        }

        String agendaBlock = '';
        if (String.isNotBlank(cfg.agenda)) {
            agendaBlock = '<div style="background:#f0f7ff;border-left:4px solid #2563eb;'
                + 'border-radius:0 6px 6px 0;padding:12px 16px;margin:16px 0;'
                + 'font-size:13px;color:#1e3a5f">'
                + '<strong>Agenda:</strong><br>' + cfg.agenda + '</div>';
        }

        return '<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body>'
            + '<div style="max-width:620px;margin:32px auto;background:#fff;'
            + 'border-radius:12px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,.10);'
            + 'font-family:\'Segoe UI\',Arial,sans-serif">'

            + '<div style="background:' + bannerColor + ';padding:36px 32px;text-align:center">'
            + '<h1 style="color:#fff;margin:0 0 6px;font-size:22px;font-weight:700">'
            + bannerIcon + '&nbsp; ' + bannerTitle + '</h1>'
            + '<p style="color:rgba(255,255,255,.85);margin:0;font-size:13px">' + bannerSub + '</p>'
            + '</div>'

            + '<div style="padding:32px">'
            + '<p style="font-size:15px;color:#222">Hi,</p>'
            + '<p style="font-size:14px;color:#444">You are invited to the following Zoom meeting:</p>'

            + '<div style="background:#f8faff;border:1px solid #dde8f5;border-radius:8px;'
            + 'padding:20px 24px;margin:20px 0">'
            + '<p style="font-size:18px;font-weight:700;color:#1a202c;margin:0 0 10px">'
            + cfg.topic + '</p>'
            + (String.isNotBlank(timeDisplay)
                ? '<p style="font-size:13px;color:#666;margin:6px 0">&#128336;&nbsp; ' + timeDisplay + '</p>'
                : '')
            + '<p style="font-size:13px;color:#666;margin:6px 0">&#9200;&nbsp; <strong>Duration:</strong> '
            + (cfg.duration != null ? cfg.duration : 60) + ' minutes</p>'
            + meetingIdBlock
            + passwordBlock
            + '</div>'

            + agendaBlock
            + joinBlock

            + '<div style="background:#f0fff4;border-left:4px solid #22c55e;border-radius:0 6px 6px 0;'
            + 'padding:12px 16px;font-size:13px;color:#166534;margin-top:16px">'
            + '&#128197;&nbsp; <strong>Add to Calendar:</strong> '
            + 'A calendar invite (.ics) is attached. Open it to add this meeting to your calendar.</div>'
            + '</div>'

            + '<div style="background:#f7faff;border-top:1px solid #e8edf3;padding:18px 32px;'
            + 'text-align:center;font-size:11px;color:#9aa5b4">'
            + 'Sent via Salesforce &nbsp;|&nbsp; Please do not reply</div>'
            + '</div></body></html>';
    }

    // Generates the METHOD:REQUEST .ics body for a new booking or reschedule.
    private static String generateNewBookingIcs(
        MeetingConfig cfg,
        String        uid,
        String        joinUrl,
        String        actionStr
    ) {
        String  CR  = '\r\n';
        String  tz  = String.isNotBlank(cfg.familyTimezone) ? cfg.familyTimezone : 'UTC';
        Integer seq = (cfg.sequenceNumber != null) ? cfg.sequenceNumber : 0;

        if (actionStr == 'RESCHEDULE' && seq == 0) {
            seq = 1;
        }

        String dtStamp = toIcsDate(DateTime.now()) + 'Z';
        String dtStart = '';
        String dtEnd   = '';
        if (cfg.startTime != null) {
            dtStart = toIcsDate(cfg.startTime);
            dtEnd   = toIcsDate(
                cfg.startTime.addMinutes(cfg.duration != null ? cfg.duration : 60)
            );
        }

        String orgEmail = String.isNotBlank(cfg.organizerEmail)
            ? cfg.organizerEmail : 'noreply@yourorg.com';
        String orgName  = String.isNotBlank(cfg.organizerName)
            ? cfg.organizerName  : 'Meeting Organizer';

        String description = 'Join Zoom Meeting:\\n' + (String.isNotBlank(joinUrl) ? joinUrl : '');
        if (String.isNotBlank(cfg.agenda)) {
            description += '\\n\\nAgenda:\\n' + cfg.agenda;
        }

        String ics = '';
        ics += 'BEGIN:VCALENDAR'                                        + CR;
        ics += 'VERSION:2.0'                                            + CR;
        ics += 'PRODID:-//YourOrg//Salesforce//EN'                     + CR;
        ics += 'CALSCALE:GREGORIAN'                                     + CR;
        ics += 'METHOD:REQUEST'                                         + CR;
        ics += buildTzBlock(tz, CR);
        ics += 'BEGIN:VEVENT'                                           + CR;
        ics += 'UID:'      + uid                                        + CR;
        ics += 'SEQUENCE:' + seq                                        + CR;
        ics += 'DTSTAMP:'  + dtStamp                                    + CR;
        if (String.isNotBlank(dtStart)) {
            ics += 'DTSTART;TZID=' + tz + ':' + dtStart                + CR;
            ics += 'DTEND;TZID='   + tz + ':' + dtEnd                  + CR;
        }
        ics += 'SUMMARY:'     + cleanIcsText(cfg.topic)                + CR;
        ics += 'DESCRIPTION:' + cleanIcsText(description)              + CR;
        if (String.isNotBlank(joinUrl)) {
            ics += 'URL:'     + joinUrl                                 + CR;
        }
        ics += 'STATUS:CONFIRMED'                                       + CR;
        ics += 'ORGANIZER;CN=' + cleanIcsText(orgName)
             + ':mailto:' + orgEmail                                    + CR;
        if (cfg.recipientEmails != null) {
            for (String ea : cfg.recipientEmails) {
                if (String.isNotBlank(ea)) {
                    ics += 'ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT'
                         + ';PARTSTAT=NEEDS-ACTION;RSVP=TRUE'
                         + ':mailto:' + ea.trim()                       + CR;
                }
            }
        }
        ics += 'END:VEVENT'                                             + CR;
        ics += 'END:VCALENDAR'                                          + CR;

        return ics;
    }

    // Saves the .ics blob as a ContentVersion file and optionally links it to a record.
    public static String saveIcsAsContentVersion(
        String  icsContent,
        String  fileName,
        String  linkedRecordId
    ) {
        try {
            ContentVersion cv  = new ContentVersion();
            cv.Title           = fileName;
            cv.PathOnClient    = fileName + '.ics';
            cv.VersionData     = Blob.valueOf(icsContent);
            cv.ContentLocation = 'S';
            insert cv;

            ContentVersion inserted = [
                SELECT ContentDocumentId
                FROM   ContentVersion
                WHERE  Id = :cv.Id
                LIMIT  1
            ];
            String docId = inserted.ContentDocumentId;
            System.debug('ContentVersion saved. DocId: ' + docId);

            if (String.isNotBlank(linkedRecordId)) {
                ContentDocumentLink cdl = new ContentDocumentLink();
                cdl.ContentDocumentId   = docId;
                cdl.LinkedEntityId      = linkedRecordId;
                cdl.ShareType           = 'V';
                cdl.Visibility          = 'AllUsers';
                insert cdl;
                System.debug('ContentDocumentLink created for record: ' + linkedRecordId);
            }

            return docId;
        } catch (Exception ex) {
            System.debug('saveIcsAsContentVersion Error: ' + ex.getMessage());
            return null;
        }
    }

    // Builds the JSON body for the Zoom Create/Update Meeting REST call.
    private static Map<String, Object> buildZoomBody(MeetingConfig cfg) {
        Map<String, Object> body = new Map<String, Object>();
        body.put('topic',      cfg.topic);
        body.put('type',       2);
        body.put('duration',   cfg.duration != null ? cfg.duration : 60);
        body.put('start_time', cfg.startTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        body.put('timezone',   String.isNotBlank(cfg.familyTimezone)
                                ? cfg.familyTimezone : 'UTC');

        if (String.isNotBlank(cfg.agenda))   body.put('agenda',   cfg.agenda);
        if (String.isNotBlank(cfg.password)) body.put('password', cfg.password);

        Map<String, Object> settings = new Map<String, Object>();
        settings.put('host_video',        false);
        settings.put('participant_video', false);
        settings.put('join_before_host',  false);
        settings.put('mute_upon_entry',   cfg.muteParticipantsOnEntry != null
                                            ? cfg.muteParticipantsOnEntry : true);
        settings.put('waiting_room',      true);
        settings.put('auto_recording',    'none');
        body.put('settings', settings);
        return body;
    }

    // Sends the cancellation email with METHOD:CANCEL .ics so calendar clients remove the event.
    private static void sendCancellationEmail(MeetingConfig cfg, String uid) {
        try {
            String icsContent = generateCancelIcs(cfg, uid);

            List<Messaging.SingleEmailMessage> emailList =
                new List<Messaging.SingleEmailMessage>();

            for (String emailAddr : cfg.recipientEmails) {
                if (String.isBlank(emailAddr)) continue;

                Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setToAddresses(new List<String>{ emailAddr.trim() });
                mail.setSubject('Cancelled: ' + cfg.topic);
                mail.setHtmlBody(buildCancelEmailHtml(cfg));

                Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
                att.setFileName(cfg.topic + '.ics');
                att.setBody(Blob.valueOf(icsContent));
                att.setContentType('text/calendar; method=CANCEL; charset=UTF-8');
                mail.setFileAttachments(
                    new List<Messaging.EmailFileAttachment>{ att }
                );

                emailList.add(mail);
            }

            if (!emailList.isEmpty()) {
                Messaging.sendEmail(emailList);
                System.debug('Cancellation email sent!');
            }
        } catch (Exception ex) {
            System.debug('sendCancellationEmail Exception: ' + ex.getMessage());
        }
    }

    // Generates the METHOD:CANCEL .ics body that removes the event from recipients' calendars.
    private static String generateCancelIcs(MeetingConfig cfg, String uid) {
        String CR  = '\r\n';
        String tz  = String.isNotBlank(cfg.familyTimezone) ? cfg.familyTimezone : 'UTC';
        Integer seq = (cfg.sequenceNumber != null) ? cfg.sequenceNumber : 1;

        String dtStamp = toIcsDate(DateTime.now()) + 'Z';
        String dtStart = '';
        String dtEnd   = '';
        if (cfg.startTime != null) {
            dtStart = toIcsDate(cfg.startTime);
            dtEnd   = toIcsDate(
                cfg.startTime.addMinutes(cfg.duration != null ? cfg.duration : 60)
            );
        }

        String orgEmail = String.isNotBlank(cfg.organizerEmail)
            ? cfg.organizerEmail : 'noreply@yourorg.com';
        String orgName  = String.isNotBlank(cfg.organizerName)
            ? cfg.organizerName  : 'Meeting Organizer';

        String ics = '';
        ics += 'BEGIN:VCALENDAR'                                        + CR;
        ics += 'VERSION:2.0'                                            + CR;
        ics += 'PRODID:-//YourOrg//Salesforce//EN'                     + CR;
        ics += 'CALSCALE:GREGORIAN'                                     + CR;
        ics += 'METHOD:CANCEL'                                          + CR;
        ics += buildTzBlock(tz, CR);
        ics += 'BEGIN:VEVENT'                                           + CR;
        ics += 'UID:'      + uid                                        + CR;
        ics += 'SEQUENCE:' + seq                                        + CR;
        ics += 'DTSTAMP:'  + dtStamp                                    + CR;
        if (String.isNotBlank(dtStart)) {
            ics += 'DTSTART;TZID=' + tz + ':' + dtStart                + CR;
            ics += 'DTEND;TZID='   + tz + ':' + dtEnd                  + CR;
        }
        ics += 'SUMMARY:'  + cleanIcsText(cfg.topic)                   + CR;
        ics += 'STATUS:CANCELLED'                                       + CR;
        ics += 'ORGANIZER;CN=' + cleanIcsText(orgName)
             + ':mailto:' + orgEmail                                    + CR;
        if (cfg.recipientEmails != null) {
            for (String ea : cfg.recipientEmails) {
                if (String.isNotBlank(ea)) {
                    ics += 'ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT'
                         + ';PARTSTAT=NEEDS-ACTION;RSVP=TRUE'
                         + ':mailto:' + ea.trim()                       + CR;
                }
            }
        }
        ics += 'END:VEVENT'                                             + CR;
        ics += 'END:VCALENDAR'                                          + CR;

        return ics;
    }

    // Builds the HTML body used for the cancellation email.
    private static String buildCancelEmailHtml(MeetingConfig cfg) {
        String timeDisplay = '';
        if (cfg.startTime != null) {
            timeDisplay = cfg.startTime.format('EEEE, MMMM d, yyyy')
                + ' at ' + cfg.startTime.format('h:mm a');
        }
        return '<!DOCTYPE html><html><head><meta charset="UTF-8">'
            + '<style>'
            + 'body{margin:0;padding:0;background:#f0f4f8;font-family:\'Segoe UI\',Arial,sans-serif}'
            + '.outer{max-width:620px;margin:32px auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,.10)}'
            + '.banner{background:#dc3545;padding:36px 32px;text-align:center}'
            + '.banner h1{color:#fff;margin:0 0 6px;font-size:22px;font-weight:700}'
            + '.banner p{color:rgba(255,255,255,.85);margin:0;font-size:13px}'
            + '.body{padding:32px}'
            + '.card{background:#fff5f5;border:1px solid #fdd;border-radius:8px;padding:20px 24px;margin:20px 0}'
            + '.tip{background:#fff5f5;border-left:4px solid #dc3545;border-radius:0 6px 6px 0;padding:12px 16px;font-size:13px;color:#7a1c1c;margin-bottom:24px}'
            + '.footer{background:#f7faff;border-top:1px solid #e8edf3;padding:18px 32px;text-align:center;font-size:11px;color:#9aa5b4}'
            + '</style></head><body>'
            + '<div class="outer">'
            + '<div class="banner">'
            + '<h1>&#10060;&nbsp; Meeting Cancelled</h1>'
            + '<p>This meeting has been cancelled</p>'
            + '</div>'
            + '<div class="body">'
            + '<p style="font-size:15px;color:#222">Hi,</p>'
            + '<p style="font-size:14px;color:#444">The following meeting has been <strong>cancelled</strong>:</p>'
            + '<div class="card">'
            + '<p style="font-size:17px;font-weight:700;color:#1a202c;margin:0 0 8px">' + cfg.topic + '</p>'
            + (String.isNotBlank(timeDisplay)
                ? '<p style="font-size:13px;color:#666;margin:0">&#128336;&nbsp; ' + timeDisplay + '</p>'
                : '')
            + '</div>'
            + '<div class="tip">&#128197;&nbsp; <strong>Calendar Update:</strong> '
            + 'A cancellation file (.ics) is attached. '
            + 'Open it to automatically remove this event from your calendar.</div>'
            + '</div>'
            + '<div class="footer">Sent via Salesforce &nbsp;|&nbsp; Please do not reply</div>'
            + '</div></body></html>';
    }

    // Returns a VTIMEZONE block matching the given IANA tz id (default: UTC).
    private static String buildTzBlock(String tz, String CR) {
        if (tz == 'America/New_York' || tz == 'America/Detroit'
         || tz == 'America/Indiana/Indianapolis') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                         + CR;
            b += 'TZID:' + tz                              + CR;
            b += 'BEGIN:STANDARD'                          + CR;
            b += 'DTSTART:19671029T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11' + CR;
            b += 'TZOFFSETFROM:-0400'                      + CR;
            b += 'TZOFFSETTO:-0500'                        + CR;
            b += 'TZNAME:EST'                              + CR;
            b += 'END:STANDARD'                            + CR;
            b += 'BEGIN:DAYLIGHT'                          + CR;
            b += 'DTSTART:19870405T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3'  + CR;
            b += 'TZOFFSETFROM:-0500'                      + CR;
            b += 'TZOFFSETTO:-0400'                        + CR;
            b += 'TZNAME:EDT'                              + CR;
            b += 'END:DAYLIGHT'                            + CR;
            b += 'END:VTIMEZONE'                           + CR;
            return b;
        }
        if (tz == 'America/Chicago' || tz == 'America/Menominee') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                         + CR;
            b += 'TZID:' + tz                              + CR;
            b += 'BEGIN:STANDARD'                          + CR;
            b += 'DTSTART:19671029T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11' + CR;
            b += 'TZOFFSETFROM:-0500'                      + CR;
            b += 'TZOFFSETTO:-0600'                        + CR;
            b += 'TZNAME:CST'                              + CR;
            b += 'END:STANDARD'                            + CR;
            b += 'BEGIN:DAYLIGHT'                          + CR;
            b += 'DTSTART:19870405T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3'  + CR;
            b += 'TZOFFSETFROM:-0600'                      + CR;
            b += 'TZOFFSETTO:-0500'                        + CR;
            b += 'TZNAME:CDT'                              + CR;
            b += 'END:DAYLIGHT'                            + CR;
            b += 'END:VTIMEZONE'                           + CR;
            return b;
        }
        if (tz == 'America/Denver' || tz == 'America/Boise') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                         + CR;
            b += 'TZID:' + tz                              + CR;
            b += 'BEGIN:STANDARD'                          + CR;
            b += 'DTSTART:19671029T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11' + CR;
            b += 'TZOFFSETFROM:-0600'                      + CR;
            b += 'TZOFFSETTO:-0700'                        + CR;
            b += 'TZNAME:MST'                              + CR;
            b += 'END:STANDARD'                            + CR;
            b += 'BEGIN:DAYLIGHT'                          + CR;
            b += 'DTSTART:19870405T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3'  + CR;
            b += 'TZOFFSETFROM:-0700'                      + CR;
            b += 'TZOFFSETTO:-0600'                        + CR;
            b += 'TZNAME:MDT'                              + CR;
            b += 'END:DAYLIGHT'                            + CR;
            b += 'END:VTIMEZONE'                           + CR;
            return b;
        }
        if (tz == 'America/Phoenix') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'         + CR;
            b += 'TZID:America/Phoenix'    + CR;
            b += 'BEGIN:STANDARD'          + CR;
            b += 'DTSTART:19700101T000000' + CR;
            b += 'TZOFFSETFROM:-0700'      + CR;
            b += 'TZOFFSETTO:-0700'        + CR;
            b += 'TZNAME:MST'              + CR;
            b += 'END:STANDARD'            + CR;
            b += 'END:VTIMEZONE'           + CR;
            return b;
        }
        if (tz == 'America/Los_Angeles') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                         + CR;
            b += 'TZID:America/Los_Angeles'                + CR;
            b += 'BEGIN:STANDARD'                          + CR;
            b += 'DTSTART:19671029T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11' + CR;
            b += 'TZOFFSETFROM:-0700'                      + CR;
            b += 'TZOFFSETTO:-0800'                        + CR;
            b += 'TZNAME:PST'                              + CR;
            b += 'END:STANDARD'                            + CR;
            b += 'BEGIN:DAYLIGHT'                          + CR;
            b += 'DTSTART:19870405T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3'  + CR;
            b += 'TZOFFSETFROM:-0800'                      + CR;
            b += 'TZOFFSETTO:-0700'                        + CR;
            b += 'TZNAME:PDT'                              + CR;
            b += 'END:DAYLIGHT'                            + CR;
            b += 'END:VTIMEZONE'                           + CR;
            return b;
        }
        if (tz == 'Pacific/Honolulu') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'          + CR;
            b += 'TZID:Pacific/Honolulu'    + CR;
            b += 'BEGIN:STANDARD'           + CR;
            b += 'DTSTART:19700101T000000'  + CR;
            b += 'TZOFFSETFROM:-1000'       + CR;
            b += 'TZOFFSETTO:-1000'         + CR;
            b += 'TZNAME:HST'               + CR;
            b += 'END:STANDARD'             + CR;
            b += 'END:VTIMEZONE'            + CR;
            return b;
        }
        if (tz == 'America/Anchorage') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                         + CR;
            b += 'TZID:America/Anchorage'                  + CR;
            b += 'BEGIN:STANDARD'                          + CR;
            b += 'DTSTART:19671029T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11' + CR;
            b += 'TZOFFSETFROM:-0800'                      + CR;
            b += 'TZOFFSETTO:-0900'                        + CR;
            b += 'TZNAME:AKST'                             + CR;
            b += 'END:STANDARD'                            + CR;
            b += 'BEGIN:DAYLIGHT'                          + CR;
            b += 'DTSTART:19870405T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3'  + CR;
            b += 'TZOFFSETFROM:-0900'                      + CR;
            b += 'TZOFFSETTO:-0800'                        + CR;
            b += 'TZNAME:AKDT'                             + CR;
            b += 'END:DAYLIGHT'                            + CR;
            b += 'END:VTIMEZONE'                           + CR;
            return b;
        }
        if (tz == 'Europe/London') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                          + CR;
            b += 'TZID:Europe/London'                       + CR;
            b += 'BEGIN:STANDARD'                           + CR;
            b += 'DTSTART:19701025T020000'                  + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10' + CR;
            b += 'TZOFFSETFROM:+0100'                       + CR;
            b += 'TZOFFSETTO:+0000'                         + CR;
            b += 'TZNAME:GMT'                               + CR;
            b += 'END:STANDARD'                             + CR;
            b += 'BEGIN:DAYLIGHT'                           + CR;
            b += 'DTSTART:19700329T010000'                  + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3'  + CR;
            b += 'TZOFFSETFROM:+0000'                       + CR;
            b += 'TZOFFSETTO:+0100'                         + CR;
            b += 'TZNAME:BST'                               + CR;
            b += 'END:DAYLIGHT'                             + CR;
            b += 'END:VTIMEZONE'                            + CR;
            return b;
        }
        if (tz == 'Europe/Paris' || tz == 'Europe/Berlin'
         || tz == 'Europe/Rome'  || tz == 'Europe/Madrid') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                          + CR;
            b += 'TZID:' + tz                               + CR;
            b += 'BEGIN:STANDARD'                           + CR;
            b += 'DTSTART:19701025T030000'                  + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10' + CR;
            b += 'TZOFFSETFROM:+0200'                       + CR;
            b += 'TZOFFSETTO:+0100'                         + CR;
            b += 'TZNAME:CET'                               + CR;
            b += 'END:STANDARD'                             + CR;
            b += 'BEGIN:DAYLIGHT'                           + CR;
            b += 'DTSTART:19700329T020000'                  + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3'  + CR;
            b += 'TZOFFSETFROM:+0100'                       + CR;
            b += 'TZOFFSETTO:+0200'                         + CR;
            b += 'TZNAME:CEST'                              + CR;
            b += 'END:DAYLIGHT'                             + CR;
            b += 'END:VTIMEZONE'                            + CR;
            return b;
        }
        if (tz == 'Asia/Kolkata') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'         + CR;
            b += 'TZID:Asia/Kolkata'       + CR;
            b += 'BEGIN:STANDARD'          + CR;
            b += 'DTSTART:19700101T000000' + CR;
            b += 'TZOFFSETFROM:+0530'      + CR;
            b += 'TZOFFSETTO:+0530'        + CR;
            b += 'TZNAME:IST'              + CR;
            b += 'END:STANDARD'            + CR;
            b += 'END:VTIMEZONE'           + CR;
            return b;
        }
        if (tz == 'Asia/Dubai' || tz == 'Asia/Muscat') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'         + CR;
            b += 'TZID:' + tz              + CR;
            b += 'BEGIN:STANDARD'          + CR;
            b += 'DTSTART:19700101T000000' + CR;
            b += 'TZOFFSETFROM:+0400'      + CR;
            b += 'TZOFFSETTO:+0400'        + CR;
            b += 'TZNAME:GST'              + CR;
            b += 'END:STANDARD'            + CR;
            b += 'END:VTIMEZONE'           + CR;
            return b;
        }
        if (tz == 'Asia/Singapore' || tz == 'Asia/Kuala_Lumpur') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'         + CR;
            b += 'TZID:' + tz              + CR;
            b += 'BEGIN:STANDARD'          + CR;
            b += 'DTSTART:19700101T000000' + CR;
            b += 'TZOFFSETFROM:+0800'      + CR;
            b += 'TZOFFSETTO:+0800'        + CR;
            b += 'TZNAME:SGT'              + CR;
            b += 'END:STANDARD'            + CR;
            b += 'END:VTIMEZONE'           + CR;
            return b;
        }
        if (tz == 'Australia/Sydney' || tz == 'Australia/Melbourne') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                         + CR;
            b += 'TZID:' + tz                              + CR;
            b += 'BEGIN:STANDARD'                          + CR;
            b += 'DTSTART:19700405T030000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4'  + CR;
            b += 'TZOFFSETFROM:+1100'                      + CR;
            b += 'TZOFFSETTO:+1000'                        + CR;
            b += 'TZNAME:AEST'                             + CR;
            b += 'END:STANDARD'                            + CR;
            b += 'BEGIN:DAYLIGHT'                          + CR;
            b += 'DTSTART:19701004T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10' + CR;
            b += 'TZOFFSETFROM:+1000'                      + CR;
            b += 'TZOFFSETTO:+1100'                        + CR;
            b += 'TZNAME:AEDT'                             + CR;
            b += 'END:DAYLIGHT'                            + CR;
            b += 'END:VTIMEZONE'                           + CR;
            return b;
        }
        if (tz == 'America/Toronto' || tz == 'Canada/Eastern') {
            String b = '';
            b += 'BEGIN:VTIMEZONE'                         + CR;
            b += 'TZID:' + tz                              + CR;
            b += 'BEGIN:STANDARD'                          + CR;
            b += 'DTSTART:19671029T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11' + CR;
            b += 'TZOFFSETFROM:-0400'                      + CR;
            b += 'TZOFFSETTO:-0500'                        + CR;
            b += 'TZNAME:EST'                              + CR;
            b += 'END:STANDARD'                            + CR;
            b += 'BEGIN:DAYLIGHT'                          + CR;
            b += 'DTSTART:19870405T020000'                 + CR;
            b += 'RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3'  + CR;
            b += 'TZOFFSETFROM:-0500'                      + CR;
            b += 'TZOFFSETTO:-0400'                        + CR;
            b += 'TZNAME:EDT'                              + CR;
            b += 'END:DAYLIGHT'                            + CR;
            b += 'END:VTIMEZONE'                           + CR;
            return b;
        }
        String b = '';
        b += 'BEGIN:VTIMEZONE'         + CR;
        b += 'TZID:UTC'                + CR;
        b += 'BEGIN:STANDARD'          + CR;
        b += 'DTSTART:16010101T000000' + CR;
        b += 'TZOFFSETFROM:+0000'      + CR;
        b += 'TZOFFSETTO:+0000'        + CR;
        b += 'TZNAME:UTC'              + CR;
        b += 'END:STANDARD'            + CR;
        b += 'END:VTIMEZONE'           + CR;
        return b;
    }

    // Formats a DateTime into the basic-form ICS timestamp (yyyyMMddTHHmmss).
    private static String toIcsDate(DateTime dt) {
        return dt.formatGmt('yyyyMMdd') + 'T' + dt.formatGmt('HHmmss');
    }

    // Escapes backslash / semicolon / comma per RFC 5545 ICS text rules.
    private static String cleanIcsText(String txt) {
        if (String.isBlank(txt)) return '';
        txt = txt.replace('\\', '\\\\');
        txt = txt.replace(';', '\\;');
        txt = txt.replace(',', '\\,');
        return txt;
    }

    // Generates a globally-unique UID (UUID-shaped) for the ICS event.
    private static String generateUniqueId() {
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        return hex.substring(0, 8)  + '-'
             + hex.substring(8,  12) + '-'
             + hex.substring(12, 16) + '-'
             + hex.substring(16, 20) + '-'
             + hex.substring(20, 32)
             + '@yourdomain.com';
    }
}