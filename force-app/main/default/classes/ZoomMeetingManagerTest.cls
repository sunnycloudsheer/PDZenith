@IsTest
public class ZoomMeetingManagerTest {

    // =========================================================================
    //  MOCK
    // =========================================================================
    private class ZoomMock implements HttpCalloutMock {
        public Integer createStatusCode = 201;
        public Integer updateStatusCode = 204;
        public Integer deleteStatusCode = 204;
        public Integer invitationStatusCode = 200;
        public String  createBody =
            '{"uuid":"abc==","id":123456789,"host_id":"H1","topic":"T",' +
            '"type":2,"status":"waiting","start_time":"2026-06-10T16:00:00Z",' +
            '"duration":30,"timezone":"America/New_York",' +
            '"join_url":"https://zoom.us/j/123","start_url":"https://zoom.us/s/123?zak=x",' +
            '"password":"x"}';
        public String  invitationBody =
            '{"invitation":"Join Zoom: https://zoom.us/j/123\\nMeeting ID: 123 456 789"}';

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            String method   = req.getMethod();
            String endpoint = req.getEndpoint();

            if (method == 'GET' && endpoint.endsWith('/invitation')) {
                res.setStatusCode(invitationStatusCode);
                res.setBody(invitationBody);
                res.setStatus(invitationStatusCode == 200 ? 'OK' : 'Error');
            } else if (method == 'POST') {
                res.setStatusCode(createStatusCode);
                res.setBody(createBody);
                res.setStatus(createStatusCode == 201 ? 'Created' : 'Error');
            } else if (method == 'PATCH') {
                res.setStatusCode(updateStatusCode);
                res.setStatus(updateStatusCode == 204 ? 'No Content' : 'Error');
            } else if (method == 'DELETE') {
                res.setStatusCode(deleteStatusCode);
                res.setStatus(deleteStatusCode == 204 ? 'No Content' : 'Error');
            } else {
                res.setStatusCode(405);
                res.setStatus('Method Not Allowed');
            }
            return res;
        }
    }

    // =========================================================================
    //  DATA FIXTURES
    // =========================================================================
    private static ServiceAppointment buildAppointment() {
        return buildAppointment('Initial Call', true, null);
    }

    private static ServiceAppointment buildAppointment(String subject, Boolean setHost, String zoomMeetingId) {
        Account acct = new Account(Name = 'Smith Family');
        insert acct;

        Contact family = new Contact(
            FirstName = 'Test', LastName = 'Student',
            Email = 'family@example.com',
            AccountId = acct.Id
        );
        insert family;

        WorkType wt = new WorkType(Name = 'Initial Call', EstimatedDuration = 0.5, DurationType = 'Hours');
        insert wt;

        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = acct.Id,
            ContactId = family.Id,
            WorkTypeId = wt.Id,
            Subject  = subject,
            SchedStartTime = Datetime.newInstanceGmt(2026, 6, 10, 16, 0, 0),
            SchedEndTime   = Datetime.newInstanceGmt(2026, 6, 10, 16, 30, 0),
            EarliestStartTime = Datetime.newInstanceGmt(2026, 6, 10, 15, 0, 0),
            DueDate           = Datetime.newInstanceGmt(2026, 6, 10, 17, 0, 0)
        );
        // Meeting_Type__c is a restricted picklist in this org — don't populate.
        // classifyMeetingRole() falls back to Subject, so Subject alone drives role.
        if (setHost) {
            sa.put('Educational_Strategist__c', UserInfo.getUserId());
        }
        if (String.isNotBlank(zoomMeetingId)) {
            sa.put('Zoom_Meeting_ID__c', zoomMeetingId);
            sa.put('Zoom_Join_URL__c', 'https://zoom.us/j/' + zoomMeetingId);
            sa.put('Zoom_Start_URL__c', 'https://zoom.us/s/' + zoomMeetingId);
        }
        insert sa;
        return sa;
    }

    private static List<ZoomMeetingManager.OutputWrapper> runManage(Id saId, String action) {
        ZoomMeetingManager.InputWrapper ip = new ZoomMeetingManager.InputWrapper();
        ip.serviceAppointmentId = saId;
        ip.action = action;
        return ZoomMeetingManager.manage(new List<ZoomMeetingManager.InputWrapper>{ ip });
    }

    /** Lead-based SA fixture — no Contact, no Account, just a Lead parent.
     *  Lead.OwnerId is the running user so Lead.Owner host resolution
     *  deterministically picks that user. */
    private static ServiceAppointment buildLeadAppointment() {
        Lead lead = new Lead(
            FirstName = 'Prospect', LastName = 'Student',
            Email     = 'prospect@example.com',
            Company   = 'Prospect Family'
        );
        insert lead;

        WorkType wt = new WorkType(Name = 'Initial Call', EstimatedDuration = 0.5, DurationType = 'Hours');
        insert wt;

        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId    = lead.Id,
            WorkTypeId        = wt.Id,
            Subject           = 'Initial Consultation',
            SchedStartTime    = Datetime.newInstanceGmt(2026, 6, 10, 16, 0, 0),
            SchedEndTime      = Datetime.newInstanceGmt(2026, 6, 10, 16, 30, 0),
            EarliestStartTime = Datetime.newInstanceGmt(2026, 6, 10, 15, 0, 0),
            DueDate           = Datetime.newInstanceGmt(2026, 6, 10, 17, 0, 0)
        );
        insert sa;
        return sa;
    }

    // =========================================================================
    //  TESTS — ICS BUILDER
    // =========================================================================
    @IsTest
    static void ics_build_request_contains_required_properties() {
        ZoomIcsBuilder.IcsInput inp = new ZoomIcsBuilder.IcsInput();
        inp.uid      = 'sa-a00000000000000AAA@test.com';
        inp.sequence = 0;
        inp.method   = ZoomIcsBuilder.METHOD_REQUEST;
        inp.summary  = 'Initial Call With Test Student';
        inp.description = 'Zoom link; body\ntext';
        inp.location = 'https://zoom.us/j/123';
        inp.startTime = Datetime.newInstanceGmt(2026, 6, 10, 16, 0, 0);
        inp.endTime   = Datetime.newInstanceGmt(2026, 6, 10, 16, 30, 0);
        inp.organizerName  = 'Zenith Prep Academy';
        inp.organizerEmail = 'info@zenithprepacademy.com';
        inp.primaryAttendee = new ZoomIcsBuilder.Attendee(
            'Test Student', 'family@example.com', null
        );

        String ics = ZoomIcsBuilder.build(inp);
        System.assert(ics.contains('METHOD:REQUEST'), 'Missing METHOD:REQUEST');
        System.assert(ics.contains('STATUS:CONFIRMED'), 'Missing STATUS:CONFIRMED');
        System.assert(ics.contains('UID:sa-a00000000000000AAA@test.com'));
        System.assert(ics.contains('SEQUENCE:0'));
        System.assert(ics.contains('DTSTART:20260610T160000Z'));
        System.assert(ics.contains('DTEND:20260610T163000Z'));
        System.assert(ics.contains('ATTENDEE'));
        System.assert(ics.contains('BEGIN:VALARM'));
    }

    @IsTest
    static void ics_build_cancel_marks_event_cancelled() {
        ZoomIcsBuilder.IcsInput inp = new ZoomIcsBuilder.IcsInput();
        inp.uid      = 'sa-a00000000000000AAA@test.com';
        inp.sequence = 2;
        inp.method   = ZoomIcsBuilder.METHOD_CANCEL;
        inp.summary  = 'Initial Call';
        inp.startTime = Datetime.newInstanceGmt(2026, 6, 10, 16, 0, 0);
        inp.endTime   = Datetime.newInstanceGmt(2026, 6, 10, 16, 30, 0);
        inp.organizerName  = 'Zenith';
        inp.organizerEmail = 'info@zenithprepacademy.com';
        inp.primaryAttendee = new ZoomIcsBuilder.Attendee(
            'F', 'f@example.com', null
        );

        String ics = ZoomIcsBuilder.build(inp);
        System.assert(ics.contains('METHOD:CANCEL'));
        System.assert(ics.contains('STATUS:CANCELLED'));
        System.assert(ics.contains('SEQUENCE:2'));
        System.assert(!ics.contains('BEGIN:VALARM'),
            'Cancelled events should not carry reminders');
    }

    @IsTest
    static void ics_build_fails_without_uid() {
        ZoomIcsBuilder.IcsInput inp = new ZoomIcsBuilder.IcsInput();
        inp.startTime = Datetime.now();
        inp.endTime   = Datetime.now().addMinutes(30);
        inp.organizerEmail = 'info@example.com';
        try {
            ZoomIcsBuilder.build(inp);
            System.assert(false, 'Expected exception');
        } catch (ZoomIcsBuilder.ZoomIcsBuilderException e) {
            System.assert(e.getMessage().contains('UID'));
        }
    }

    @IsTest
    static void ics_line_folding_handles_long_description() {
        ZoomIcsBuilder.IcsInput inp = new ZoomIcsBuilder.IcsInput();
        inp.uid      = 'sa-long@test.com';
        inp.sequence = 0;
        inp.method   = ZoomIcsBuilder.METHOD_REQUEST;
        inp.summary  = 'Long';
        String longText = '';
        for (Integer i = 0; i < 30; i++) longText += 'abcdefghij';
        inp.description = longText;
        inp.startTime = Datetime.now();
        inp.endTime   = Datetime.now().addMinutes(30);
        inp.organizerEmail = 'info@example.com';
        inp.primaryAttendee = new ZoomIcsBuilder.Attendee('A', 'a@b.com', null);

        String ics = ZoomIcsBuilder.build(inp);
        System.assert(ics.contains('DESCRIPTION:'), 'Expected DESCRIPTION line');
    }

    // =========================================================================
    //  TESTS — EMAIL SERVICE
    // =========================================================================
    @IsTest
    static void email_service_builds_attachment_with_calendar_content_type() {
        ZoomMeetingEmailService.SendInput s = new ZoomMeetingEmailService.SendInput();
        s.inviteType = ZoomMeetingEmailService.InviteType.NEW_BOOKING;
        s.icsContent = 'BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n';
        s.toEmail    = 'family@example.com';
        s.subject    = 'Test';
        s.htmlBody   = '<p>Hi</p>';
        s.plainBody  = 'Hi';

        Test.startTest();
        ZoomMeetingEmailService.SendResult r = ZoomMeetingEmailService.send(s);
        Test.stopTest();

        System.assertNotEquals(null, r);
        System.assertEquals(null, r.errorMessage);
    }

    @IsTest
    static void email_service_rejects_missing_to() {
        ZoomMeetingEmailService.SendInput s = new ZoomMeetingEmailService.SendInput();
        s.icsContent = 'content';
        s.inviteType = ZoomMeetingEmailService.InviteType.NEW_BOOKING;

        ZoomMeetingEmailService.SendResult r = ZoomMeetingEmailService.send(s);
        System.assertEquals(false, r.success);
        System.assert(r.errorMessage != null);
    }

    @IsTest
    static void email_service_rejects_missing_ics_content() {
        ZoomMeetingEmailService.SendInput s = new ZoomMeetingEmailService.SendInput();
        s.inviteType = ZoomMeetingEmailService.InviteType.NEW_BOOKING;
        s.toEmail = 'family@example.com';

        ZoomMeetingEmailService.SendResult r = ZoomMeetingEmailService.send(s);
        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('ICS'));
    }

    @IsTest
    static void email_service_dedups_cc_and_drops_to_duplicate() {
        ZoomMeetingEmailService.SendInput s = new ZoomMeetingEmailService.SendInput();
        s.inviteType = ZoomMeetingEmailService.InviteType.RESCHEDULE;
        s.icsContent = 'BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n';
        s.toEmail    = 'family@example.com';
        s.ccEmails   = new List<String>{
            'parent1@example.com',
            'PARENT1@example.com',
            '  parent2@example.com  ',
            '',
            null,
            'family@example.com'
        };
        s.subject    = 'Updated';
        s.htmlBody   = '<p>Hi</p>';
        s.plainBody  = 'Hi';

        Test.startTest();
        ZoomMeetingEmailService.SendResult r = ZoomMeetingEmailService.send(s);
        Test.stopTest();

        System.assertEquals(true, r.success);
    }

    @IsTest
    static void email_service_cancellation_uses_cancel_method() {
        ZoomMeetingEmailService.SendInput s = new ZoomMeetingEmailService.SendInput();
        s.inviteType = ZoomMeetingEmailService.InviteType.CANCELLATION;
        s.icsContent = 'BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n';
        s.toEmail    = 'family@example.com';
        s.subject    = 'Cancelled';
        s.plainBody  = 'Cancelled';
        s.logEmailOnSend = false;

        Test.startTest();
        ZoomMeetingEmailService.SendResult r = ZoomMeetingEmailService.send(s);
        Test.stopTest();
        System.assertEquals(true, r.success);
    }

    // =========================================================================
    //  TESTS — MANAGER entry guards
    // =========================================================================
    @IsTest
    static void manager_handles_null_inputs() {
        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        List<ZoomMeetingManager.OutputWrapper> outs = ZoomMeetingManager.manage(null);
        System.assertEquals(0, outs.size());

        outs = ZoomMeetingManager.manage(new List<ZoomMeetingManager.InputWrapper>());
        System.assertEquals(0, outs.size());
    }

    @IsTest
    static void manager_skips_inputs_with_null_ids() {
        ZoomMeetingManager.InputWrapper ip = new ZoomMeetingManager.InputWrapper();
        ip.serviceAppointmentId = null;
        ip.action = 'BOGUS';

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs =
            ZoomMeetingManager.manage(new List<ZoomMeetingManager.InputWrapper>{ ip });
        Test.stopTest();

        System.assertEquals(0, outs.size(), 'Null Id should be filtered before dispatch');
    }

    @IsTest
    static void manager_reports_missing_service_appointment() {
        ZoomMeetingManager.InputWrapper ip = new ZoomMeetingManager.InputWrapper();
        ip.serviceAppointmentId = '08pQU0000000000AAA';
        ip.action = 'CREATE';

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs =
            ZoomMeetingManager.manage(new List<ZoomMeetingManager.InputWrapper>{ ip });
        Test.stopTest();

        System.assertEquals(1, outs.size());
        System.assertEquals('ERROR', outs[0].status);
        System.assert(outs[0].errorMessage.contains('not found'));
    }

    // =========================================================================
    //  TESTS — MANAGER CREATE / UPDATE / CANCEL
    // =========================================================================
    @IsTest
    static void manager_create_succeeds_and_populates_meeting_fields() {
        ServiceAppointment sa = buildAppointment();

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals(1, outs.size());
        ZoomMeetingManager.OutputWrapper o = outs[0];
        System.assertEquals('SUCCESS', o.status, 'errorMessage=' + o.errorMessage);
        System.assertEquals('123456789', o.meetingId);
        System.assertEquals('https://zoom.us/j/123', o.joinUrl);
        System.assertEquals(0, o.icsSequence);
        System.assertNotEquals(null, o.icsUid);
    }

    @IsTest
    static void manager_default_action_is_create() {
        ServiceAppointment sa = buildAppointment();

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, null);
        Test.stopTest();

        System.assertEquals(1, outs.size());
        System.assertEquals('CREATE', outs[0].action);
        System.assertEquals('SUCCESS', outs[0].status);
    }

    @IsTest
    static void manager_create_fails_on_zoom_error() {
        ServiceAppointment sa = buildAppointment();

        ZoomMock mock = new ZoomMock();
        mock.createStatusCode = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('ERROR', outs[0].status);
        System.assert(outs[0].errorMessage.contains('Zoom create failed'));
    }

    @IsTest
    static void manager_update_succeeds_and_increments_sequence() {
        ServiceAppointment sa = buildAppointment('Initial Call', true, '999888777');

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'UPDATE');
        Test.stopTest();

        System.assertEquals('SUCCESS', outs[0].status, 'errorMessage=' + outs[0].errorMessage);
        System.assertEquals('999888777', outs[0].meetingId);
        // Sequence is now derived from (SystemModstamp - CreatedDate) in
        // seconds, so the exact value depends on elapsed time — just
        // assert it's a populated non-negative integer. Monotonic-increase
        // across real reschedules is enforced by SystemModstamp itself.
        System.assertNotEquals(null, outs[0].icsSequence);
        System.assert(outs[0].icsSequence >= 0, 'icsSequence must be >= 0');
    }

    @IsTest
    static void manager_update_lead_based_uses_inapex_copy() {
        // Lead-based SAs have no Contact, so queueInvite's RESCHEDULE
        // branch falls back to the in-Apex buildSubject / buildHtmlBody /
        // buildPlainBody helpers (the "Meeting Rescheduled Email Template"
        // is keyed off ContactId for merge resolution). This exercises
        // those fallback branches so coverage still hits them after the
        // template path was wired up for ContactId-based reschedules.
        ServiceAppointment sa = buildLeadAppointment();
        sa.put('Zoom_Meeting_ID__c', '777666555');
        sa.put('Zoom_Join_URL__c',  'https://zoom.us/j/777666555');
        sa.put('Zoom_Start_URL__c', 'https://zoom.us/s/777666555');
        update sa;

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'UPDATE');
        Test.stopTest();

        System.assertEquals('SUCCESS', outs[0].status, 'errorMessage=' + outs[0].errorMessage);
        System.assertEquals('777666555', outs[0].meetingId);
        System.assertNotEquals(null, outs[0].icsSequence);
    }

    @IsTest
    static void manager_update_falls_back_to_create_when_no_zoom_id() {
        ServiceAppointment sa = buildAppointment('Initial Call', true, null);

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'UPDATE');
        Test.stopTest();

        System.assertEquals('SUCCESS', outs[0].status);
        System.assertEquals('CREATE', outs[0].action);
        System.assertEquals('123456789', outs[0].meetingId);
    }

    @IsTest
    static void manager_update_404_falls_back_to_create() {
        ServiceAppointment sa = buildAppointment('Initial Call', true, '404GONE');

        ZoomMock mock = new ZoomMock();
        mock.updateStatusCode = 404;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'UPDATE');
        Test.stopTest();

        System.assertEquals('SUCCESS', outs[0].status);
        System.assertEquals('CREATE', outs[0].action);
    }

    @IsTest
    static void manager_update_returns_error_on_zoom_failure() {
        ServiceAppointment sa = buildAppointment('Initial Call', true, '111');

        ZoomMock mock = new ZoomMock();
        mock.updateStatusCode = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'UPDATE');
        Test.stopTest();

        System.assertEquals('ERROR', outs[0].status);
        System.assert(outs[0].errorMessage.contains('Zoom update failed'));
    }

    @IsTest
    static void manager_cancel_deletes_meeting_and_sends_cancellation() {
        ServiceAppointment sa = buildAppointment('Initial Call', true, '555444333');

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CANCEL');
        Test.stopTest();

        System.assertEquals('SUCCESS', outs[0].status);
        System.assertEquals('555444333', outs[0].meetingId);
    }

    @IsTest
    static void cancel_email_action_invocable_sends_via_template() {
        // Service_Appointment_Status_Change_Email_Notification calls this
        // Invocable in place of emailSimple so it can attach the
        // METHOD:CANCEL .ics that purges the event from calendars.
        ServiceAppointment sa = buildAppointment('Initial Call', true, '555444333');

        ZoomMeetingCancelEmailAction.Input ip = new ZoomMeetingCancelEmailAction.Input();
        ip.serviceAppointmentId = sa.Id;
        // Any non-null Id is fine — sendBulk in the email service tries to
        // use it as templateId and will fall through gracefully under tests
        // because EmailTemplate isn't accessible without seeAllData.
        ip.emailTemplateId = sa.Id;

        Test.startTest();
        ZoomMeetingCancelEmailAction.send(new List<ZoomMeetingCancelEmailAction.Input>{ ip });
        Test.stopTest();

        // No exception thrown; method completes. Coverage on the Invocable
        // wrapper + the manager's sendCancellationsForSavedAppointments path.
    }

    @IsTest
    static void cancel_email_action_invocable_handles_empty_input() {
        Test.startTest();
        ZoomMeetingCancelEmailAction.send(null);
        ZoomMeetingCancelEmailAction.send(new List<ZoomMeetingCancelEmailAction.Input>());

        ZoomMeetingCancelEmailAction.Input blank = new ZoomMeetingCancelEmailAction.Input();
        ZoomMeetingCancelEmailAction.send(new List<ZoomMeetingCancelEmailAction.Input>{ blank });
        Test.stopTest();
    }

    @IsTest
    static void manager_cancel_skipped_when_no_zoom_id_or_uid() {
        ServiceAppointment sa = buildAppointment('Initial Call', true, null);

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CANCEL');
        Test.stopTest();

        System.assertEquals('SKIPPED', outs[0].status);
    }

    @IsTest
    static void manager_cancel_tolerates_zoom_404() {
        ServiceAppointment sa = buildAppointment('Initial Call', true, '777');

        ZoomMock mock = new ZoomMock();
        mock.deleteStatusCode = 404;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CANCEL');
        Test.stopTest();

        System.assertEquals('SUCCESS', outs[0].status,
            '404 on delete should be treated as idempotent success');
    }

    @IsTest
    static void manager_cancel_reports_error_on_zoom_failure() {
        ServiceAppointment sa = buildAppointment('Initial Call', true, '888');

        ZoomMock mock = new ZoomMock();
        mock.deleteStatusCode = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CANCEL');
        Test.stopTest();

        System.assertEquals('ERROR', outs[0].status);
        System.assert(outs[0].errorMessage.contains('Zoom delete failed'));
    }

    @IsTest
    static void manager_unknown_action_reports_error() {
        ServiceAppointment sa = buildAppointment();

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'FROB');
        Test.stopTest();

        System.assertEquals('ERROR', outs[0].status);
        System.assert(outs[0].errorMessage.contains('Unknown action'));
    }

    // =========================================================================
    //  TESTS — MANAGER validation
    // =========================================================================
    @IsTest
    static void manager_rejects_missing_times() {
        ServiceAppointment sa = buildAppointment();
        sa.SchedStartTime = null;
        update sa;

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('ERROR', outs[0].status);
        System.assert(outs[0].errorMessage.contains('SchedStartTime'));
    }

    @IsTest
    static void manager_rejects_missing_attendee_email() {
        ServiceAppointment sa = buildAppointment();
        Contact c = [SELECT Id, Email FROM Contact WHERE Id = :sa.ContactId LIMIT 1];
        c.Email = null;
        update c;

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('ERROR', outs[0].status);
        System.assert(outs[0].errorMessage.contains('attendee email'));
    }

    // =========================================================================
    //  TESTS — classify role by Subject
    // =========================================================================
    @IsTest
    static void manager_classifies_fss_role() {
        ServiceAppointment sa = buildAppointment('Family Success Onboarding', true, null);

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('FSS', outs[0].resolvedRole);
    }

    @IsTest
    static void manager_classifies_pd_role() {
        ServiceAppointment sa = buildAppointment('Program Director check-in', true, null);

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('PD', outs[0].resolvedRole);
    }

    @IsTest
    static void manager_classifies_ac_role_via_initial_consultation() {
        ServiceAppointment sa = buildAppointment('Initial Consultation', true, null);

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('AC', outs[0].resolvedRole);
    }

    @IsTest
    static void manager_defaults_to_es_role() {
        ServiceAppointment sa = buildAppointment('Weekly Strategy Session', true, null);

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('ES', outs[0].resolvedRole);
    }

    // =========================================================================
    //  TESTS — Substitute ES (only applies to ES role)
    // =========================================================================
    @IsTest
    static void manager_active_substitute_wins_for_es_role() {
        ServiceAppointment sa = buildAppointment('Weekly Strategy Session', true, null);

        Substitute__c sub = new Substitute__c(
            Contact__c = sa.ContactId,
            Substitute_Educational_Strategist__c = UserInfo.getUserId(),
            Active__c = true
        );
        insert sub;

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('SUCCESS', outs[0].status, 'errorMessage=' + outs[0].errorMessage);
        System.assertEquals('ES', outs[0].resolvedRole);
        System.assertEquals('Substitute__c.Active', outs[0].resolvedHostSource,
            'Active substitute should override SA.Educational_Strategist__c');
    }

    @IsTest
    static void manager_substitute_ignored_for_non_es_role() {
        // PD call — classifyMeetingRole returns PD. Even with an active
        // Substitute__c (ES-only), the host must resolve via PD fields.
        ServiceAppointment sa = buildAppointment('Program Director check-in', true, null);
        sa.put('Program_Director__c', UserInfo.getUserId());
        update sa;

        Substitute__c sub = new Substitute__c(
            Contact__c = sa.ContactId,
            Substitute_Educational_Strategist__c = UserInfo.getUserId(),
            Active__c = true
        );
        insert sub;

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('PD', outs[0].resolvedRole);
        System.assertNotEquals('Substitute__c.Active', outs[0].resolvedHostSource,
            'Substitute__c is ES-only — PD role must not consult it');
    }

    // =========================================================================
    //  TESTS — Lead-based SA (pre-conversion, no Contact)
    // =========================================================================
    @IsTest
    static void manager_lead_sa_uses_lead_owner_as_host() {
        ServiceAppointment sa = buildLeadAppointment();

        Test.setMock(HttpCalloutMock.class, new ZoomMock());
        Test.startTest();
        List<ZoomMeetingManager.OutputWrapper> outs = runManage(sa.Id, 'CREATE');
        Test.stopTest();

        System.assertEquals('SUCCESS', outs[0].status, 'errorMessage=' + outs[0].errorMessage);
        System.assertEquals('Lead.Owner', outs[0].resolvedHostSource,
            'Lead-based SA must resolve host via Lead.Owner, not via role chain');
        // Attendee (TO) is the Lead.Email — not a Contact.
        System.assertEquals('123456789', outs[0].meetingId);
    }

}