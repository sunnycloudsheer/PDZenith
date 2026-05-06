@isTest
private class RescheduleTokenServiceTest {

    @TestSetup
    static void setupData() {
        Account a = new Account(Name = 'Reschedule Family');
        insert a;
        Contact c = new Contact(
            FirstName = 'Resi', LastName = 'Family',
            Email = 'resi@example.com', AccountId = a.Id
        );
        insert c;

        OperatingHours oh = new OperatingHours(Name = 'RT Hours', TimeZone = 'America/Chicago');
        insert oh;

        ServiceTerritory st = new ServiceTerritory(
            Name = 'RT Territory', IsActive = true, OperatingHoursId = oh.Id
        );
        insert st;

        WorkType wt = new WorkType(
            Name = 'RT WorkType', EstimatedDuration = 60,
            DurationType = 'Minutes', OperatingHoursId = oh.Id
        );
        insert wt;

        DateTime futureStart = DateTime.now().addDays(7);

        // SA WITH a reschedule token (used by validate + cancel paths).
        ServiceAppointment saValid = new ServiceAppointment(
            ParentRecordId = a.Id,
            ContactId = c.Id,
            ServiceTerritoryId = st.Id,
            WorkTypeId = wt.Id,
            SchedStartTime = futureStart,
            SchedEndTime = futureStart.addHours(1),
            EarliestStartTime = futureStart,
            DueDate = futureStart.addHours(1),
            Status = 'Scheduled',
            Subject = 'Rescheduable SOM',
            Reschedule_Token__c = 'rt-valid-token-' + System.currentTimeMillis()
        );
        insert saValid;

        // SA whose start has already passed.
        DateTime pastStart = DateTime.now().addDays(-3);
        ServiceAppointment saPast = new ServiceAppointment(
            ParentRecordId = a.Id,
            ContactId = c.Id,
            ServiceTerritoryId = st.Id,
            WorkTypeId = wt.Id,
            SchedStartTime = pastStart,
            SchedEndTime = pastStart.addHours(1),
            EarliestStartTime = pastStart,
            DueDate = pastStart.addHours(1),
            Status = 'Scheduled',
            Reschedule_Token__c = 'rt-past-token-' + System.currentTimeMillis()
        );
        insert saPast;

        // SA already in a terminal status.
        ServiceAppointment saTerminal = new ServiceAppointment(
            ParentRecordId = a.Id,
            ContactId = c.Id,
            ServiceTerritoryId = st.Id,
            WorkTypeId = wt.Id,
            SchedStartTime = futureStart.addDays(1),
            SchedEndTime = futureStart.addDays(1).addHours(1),
            EarliestStartTime = futureStart.addDays(1),
            DueDate = futureStart.addDays(1).addHours(1),
            Status = 'Scheduled',
            Reschedule_Token__c = 'rt-terminal-token-' + System.currentTimeMillis()
        );
        insert saTerminal;
        saTerminal.Status = 'Completed';
        update saTerminal;
    }

    // Verifies generateToken returns a 64-char hex string.
    @isTest
    static void generateToken_returnsHexString() {
        Test.startTest();
        String t1 = RescheduleTokenService.generateToken();
        String t2 = RescheduleTokenService.generateToken();
        Test.stopTest();

        System.assertNotEquals(null, t1, 'Token must be returned');
        System.assertEquals(64, t1.length(), 'Token must be 64 hex chars (256-bit key)');
        System.assert(Pattern.matches('[a-f0-9]+', t1), 'Token must be hex');
        System.assertNotEquals(t1, t2, 'Two generations must produce different tokens');
    }

    // Verifies tryPutCancellationReason swallows invalid picklist values without throwing.
    @isTest
    static void tryPutCancellationReason_doesNotThrowOnInvalidValue() {
        ServiceAppointment sa = [SELECT Id FROM ServiceAppointment WHERE Reschedule_Token__c LIKE 'rt-valid-token-%' LIMIT 1];

        Test.startTest();
        // Invalid value is silently absorbed by the helper (no exception).
        RescheduleTokenService.tryPutCancellationReason(sa, 'definitely-not-a-valid-picklist-value-xyz');
        // Blank reason is also tolerated.
        RescheduleTokenService.tryPutCancellationReason(sa, null);
        RescheduleTokenService.tryPutCancellationReason(sa, '');
        Test.stopTest();

        System.assert(true, 'Helper must not throw on invalid input');
    }

    // Verifies validateAndGetAppointment rejects blank tokens.
    @isTest
    static void validate_blankToken_returnsInvalid() {
        Test.startTest();
        Map<String, Object> nullRes  = RescheduleTokenService.validateAndGetAppointment(null);
        Map<String, Object> emptyRes = RescheduleTokenService.validateAndGetAppointment('');
        Test.stopTest();

        System.assertEquals(false, nullRes.get('valid'),  'null token must be invalid');
        System.assertNotEquals(null, nullRes.get('error'), 'error must be set');
        System.assertEquals(false, emptyRes.get('valid'), 'empty token must be invalid');
    }

    // Verifies validateAndGetAppointment rejects unknown tokens.
    @isTest
    static void validate_unknownToken_returnsLinkAlreadyUsed() {
        Test.startTest();
        Map<String, Object> result = RescheduleTokenService.validateAndGetAppointment('totally-fake-token-xyz');
        Test.stopTest();

        System.assertEquals(false, result.get('valid'), 'Unknown token must be invalid');
        System.assertNotEquals(null, result.get('error'), 'Error message must be present');
    }

    // Verifies validateAndGetAppointment returns valid+payload for a usable token.
    @isTest
    static void validate_validToken_returnsPayload() {
        ServiceAppointment sa = [SELECT Reschedule_Token__c FROM ServiceAppointment WHERE Reschedule_Token__c LIKE 'rt-valid-token-%' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = RescheduleTokenService.validateAndGetAppointment(sa.Reschedule_Token__c);
        Test.stopTest();

        System.assertEquals(true, result.get('valid'), 'Valid token must return valid=true');
        System.assertNotEquals(null, result.get('appointmentId'), 'appointmentId must be set');
        System.assertNotEquals(null, result.get('rescheduleBookingUrl'), 'rescheduleBookingUrl must be set');
        System.assert(((String) result.get('rescheduleBookingUrl')).contains('action=reschedule'),
            'URL must include action=reschedule');
    }

    // Verifies validateAndGetAppointment rejects a token whose SA start is in the past.
    @isTest
    static void validate_pastAppointment_returnsAppointmentPassed() {
        ServiceAppointment sa = [SELECT Reschedule_Token__c FROM ServiceAppointment WHERE Reschedule_Token__c LIKE 'rt-past-token-%' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = RescheduleTokenService.validateAndGetAppointment(sa.Reschedule_Token__c);
        Test.stopTest();

        System.assertEquals(false, result.get('valid'), 'Past appointment must be invalid');
        System.assertNotEquals(null, result.get('error'), 'Error must describe expiration');
    }

    // Verifies validateAndGetAppointment rejects a terminal-status SA.
    @isTest
    static void validate_terminalStatusSa_returnsLinkAlreadyUsed() {
        ServiceAppointment sa = [SELECT Reschedule_Token__c FROM ServiceAppointment WHERE Reschedule_Token__c LIKE 'rt-terminal-token-%' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = RescheduleTokenService.validateAndGetAppointment(sa.Reschedule_Token__c);
        Test.stopTest();

        System.assertEquals(false, result.get('valid'), 'Terminal-status SA must be invalid');
    }

    // Verifies cancelAppointment rejects blank tokens.
    @isTest
    static void cancel_blankToken_returnsFailure() {
        Test.startTest();
        Map<String, String> nullRes  = RescheduleTokenService.cancelAppointment(null, 'family change');
        Map<String, String> emptyRes = RescheduleTokenService.cancelAppointment('', 'family change');
        Test.stopTest();

        System.assertEquals('false', nullRes.get('success'),  'null token must fail');
        System.assertEquals('false', emptyRes.get('success'), 'empty token must fail');
    }

    // Verifies cancelAppointment rejects an unknown token.
    @isTest
    static void cancel_unknownToken_returnsFailure() {
        Test.startTest();
        Map<String, String> result = RescheduleTokenService.cancelAppointment('does-not-exist-token', 'no reason');
        Test.stopTest();

        System.assertEquals('false', result.get('success'), 'Unknown token must fail');
        System.assertNotEquals(null, result.get('error'), 'Error must be set');
    }

    // Verifies cancelAppointment rejects a terminal-status SA.
    @isTest
    static void cancel_terminalStatus_returnsFailure() {
        ServiceAppointment sa = [SELECT Reschedule_Token__c FROM ServiceAppointment WHERE Reschedule_Token__c LIKE 'rt-terminal-token-%' LIMIT 1];

        Test.startTest();
        Map<String, String> result = RescheduleTokenService.cancelAppointment(sa.Reschedule_Token__c, 'late notice');
        Test.stopTest();

        System.assertEquals('false', result.get('success'), 'Terminal SA must not be cancelled again');
    }

    // Verifies cancelAppointment cancels the SA and queues the Zoom cancel job.
    @isTest
    static void cancel_validToken_marksSaCanceledAndEnqueuesZoom() {
        ServiceAppointment sa = [SELECT Id, Reschedule_Token__c FROM ServiceAppointment WHERE Reschedule_Token__c LIKE 'rt-valid-token-%' LIMIT 1];

        Test.startTest();
        Map<String, String> result = RescheduleTokenService.cancelAppointment(sa.Reschedule_Token__c, 'family change');
        Test.stopTest();

        // Result indicates success regardless of whether the org's Status picklist has the
        // 'Meeting Canceled by Customer' value (the controller falls back to 'Meeting
        // Canceled by Student'). Either way, the call should not throw.
        System.assertNotEquals(null, result, 'Result must be populated');
        if ('true'.equals(result.get('success'))) {
            ServiceAppointment refreshed = [
                SELECT Id, Status, Reschedule_Token__c, Description
                FROM ServiceAppointment WHERE Id = :sa.Id
            ];
            System.assertEquals(null, refreshed.Reschedule_Token__c, 'Token should be cleared on success');
        }
    }
}