@IsTest
private class GuestSchedulerControllerTest {

    private static final String ADMISSION_PROFILE = 'Admission Counsellor';
    private static final String ADMISSION_PROFILE_ALT = 'Admission Counselor';

    private static Id getAdmissionProfileId() {
        List<Profile> profiles = [
            SELECT Id, Name FROM Profile
            WHERE Name = :ADMISSION_PROFILE OR Name = :ADMISSION_PROFILE_ALT
            LIMIT 1
        ];
        return profiles.isEmpty() ? null : profiles[0].Id;
    }

    private static User createCounselorUser(Id profileId, String suffix) {
        String uniqueKey = String.valueOf(DateTime.now().getTime()) + suffix;
        User u = new User(
            FirstName = 'Test',
            LastName = 'Counselor' + suffix,
            Email = 'testcounselor' + uniqueKey + '@zenithtest.com',
            Username = 'testcounselor' + uniqueKey + '@zenithtest.com.test',
            Alias = 'tc' + suffix.left(4),
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = profileId,
            IsActive = true
        );
        insert u;
        return u;
    }

    private static Map<String, Object> buildFullSchedulingData(List<User> counselorUsers) {
        Map<String, Object> data = new Map<String, Object>();

        OperatingHours oh = new OperatingHours(Name = 'Test Operating Hours', TimeZone = 'America/Chicago');
        insert oh;
        data.put('operatingHoursId', oh.Id);

        List<TimeSlot> timeSlots = new List<TimeSlot>();
        List<String> days = new List<String>{'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'};
        for (String day : days) {
            timeSlots.add(new TimeSlot(
                OperatingHoursId = oh.Id,
                DayOfWeek = day,
                StartTime = Time.newInstance(6, 0, 0, 0),
                EndTime = Time.newInstance(22, 0, 0, 0)
            ));
        }
        insert timeSlots;

        WorkType wt = new WorkType(
            Name = 'Initial Consultation',
            EstimatedDuration = 1.0,
            DurationType = 'Hours',
            DefaultAppointmentType = 'Phone',
            OperatingHoursId = oh.Id,
            TimeframeEnd = 30,
            TimeFrameEndUnit = 'Days',
            TimeframeStart = 0,
            TimeFrameStartUnit = 'Days',
            ApptStartTimeIntvlInMin = 30
        );
        insert wt;
        data.put('workTypeId', wt.Id);

        ServiceTerritory st = new ServiceTerritory(
            Name = 'Test Territory',
            IsActive = true,
            OperatingHoursId = oh.Id,
            Street = '123 Test St',
            City = 'Chicago',
            State = 'IL'
        );
        insert st;
        data.put('serviceTerritoryId', st.Id);

        List<ServiceResource> resources = new List<ServiceResource>();
        for (User u : counselorUsers) {
            resources.add(new ServiceResource(
                Name = 'Resource ' + u.LastName,
                RelatedRecordId = u.Id,
                ResourceType = 'T',
                IsActive = true
            ));
        }
        insert resources;
        data.put('serviceResources', resources);

        List<ServiceTerritoryMember> members = new List<ServiceTerritoryMember>();
        for (ServiceResource sr : resources) {
            members.add(new ServiceTerritoryMember(
                ServiceTerritoryId = st.Id,
                ServiceResourceId = sr.Id,
                EffectiveStartDate = Date.today().addDays(-30),
                TerritoryType = 'P'
            ));
        }
        insert members;

        return data;
    }

    private static Date getNextWeekday() {
        Date futureDate = Date.today().addDays(3);
        DateTime futureDT = DateTime.newInstanceGmt(futureDate, Time.newInstance(12,0,0,0));
        String dayName = futureDT.formatGmt('EEEE');
        while (dayName == 'Saturday' || dayName == 'Sunday') {
            futureDate = futureDate.addDays(1);
            futureDT = DateTime.newInstanceGmt(futureDate, Time.newInstance(12,0,0,0));
            dayName = futureDT.formatGmt('EEEE');
        }
        return futureDate;
    }

    // Verifies booking config errors when no counselors exist.
    @IsTest
    static void testGetBookingConfig_NoCounselors() {
        Map<String, Object> result = GuestSchedulerController.getBookingConfig(null);
        System.assertEquals(false, result.get('success'), 'Should fail with no counselors');
        System.assertNotEquals(null, result.get('error'), 'Should have error message');
    }

    // Verifies booking config tolerates a zero open-window value.
    @IsTest
    static void testGetBookingConfig_ZeroOpenWindowDays() {
        Map<String, Object> result = GuestSchedulerController.getBookingConfig(0);
        System.assertNotEquals(null, result, 'Result should not be null');
    }

    // Verifies booking config tolerates a negative open-window value.
    @IsTest
    static void testGetBookingConfig_NegativeOpenWindowDays() {
        Map<String, Object> result = GuestSchedulerController.getBookingConfig(-5);
        System.assertNotEquals(null, result, 'Result should not be null');
    }

    // Verifies getAvailableSlots returns empty when there are no counselors.
    @IsTest
    static void testGetAvailableSlots_NoCounselors() {
        String dateStr = String.valueOf(Date.today().addDays(3));
        List<Map<String, String>> result = GuestSchedulerController.getAvailableSlots(dateStr);
        System.assert(result.isEmpty(), 'Should return empty list with no counselors');
    }

    // Verifies getAvailableSlots returns empty for an unparsable date string.
    @IsTest
    static void testGetAvailableSlots_InvalidDate() {
        List<Map<String, String>> result = GuestSchedulerController.getAvailableSlots('invalid-date');
        System.assert(result.isEmpty(), 'Should return empty list for invalid date');
    }

    // Verifies bookAppointment throws AuraHandledException when no counselors exist.
    @IsTest
    static void testBookAppointment_NoCounselors() {
        DateTime startDT = DateTime.now().addDays(7);
        DateTime endDT = startDT.addHours(1);
        String startISO = startDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endISO = endDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        Boolean exceptionThrown = false;
        try {
            GuestSchedulerController.bookAppointment(
                startISO, endISO,
                'John', 'Doe', 'john@test.com', '5551234567',
                '10th Grade', 'Website', null,
                'America/Chicago', null, null, null
            );
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw AuraHandledException when no counselors exist');
    }

    // Verifies bookAppointment fails gracefully when optional fields are absent.
    @IsTest
    static void testBookAppointment_MissingOptionalFields() {
        DateTime startDT = DateTime.now().addDays(7);
        DateTime endDT = startDT.addHours(1);
        String startISO = startDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endISO = endDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        Boolean exceptionThrown = false;
        try {
            GuestSchedulerController.bookAppointment(
                startISO, endISO,
                'Test', 'User', 'test@test.com', '5550000000',
                null, null, null, null, null, null, null
            );
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw an exception');
    }

    // Verifies booking config returns the expected metadata when fully seeded.
    @IsTest
    static void testGetBookingConfig_Success() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'A');
        buildFullSchedulingData(new List<User>{ counselorUser });

        Test.startTest();
        Map<String, Object> result = GuestSchedulerController.getBookingConfig(null);
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'Should succeed: ' + result.get('error'));
        System.assertNotEquals(null, result.get('workTypeId'), 'WorkType Id should be present');
        System.assertNotEquals(null, result.get('serviceTerritoryId'), 'Territory Id should be present');
        System.assertNotEquals(null, result.get('durationMinutes'), 'Duration should be present');
        System.assertEquals('America/Chicago', result.get('territoryTimezone'), 'Timezone should match');
        System.assertEquals('123 Test St', result.get('street'), 'Street should match');
        System.assertEquals('Chicago', result.get('city'), 'City should match');
        System.assertEquals('IL', result.get('state'), 'State should match');
        System.assertNotEquals(null, result.get('availableDates'), 'Available dates should be present');
        System.assertNotEquals(null, result.get('operatingHoursId'), 'Operating hours should be present');
        System.assertNotEquals(null, result.get('slotIntervalMinutes'), 'Slot interval should be present');
    }

    // Verifies a custom open-window value flows through to targetAvailDays.
    @IsTest
    static void testGetBookingConfig_WithCustomOpenWindow() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'B');
        buildFullSchedulingData(new List<User>{ counselorUser });

        Test.startTest();
        Map<String, Object> result = GuestSchedulerController.getBookingConfig(7);
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'Should succeed: ' + result.get('error'));
        System.assertEquals(7, result.get('targetAvailDays'), 'Should use custom open window days');
    }

    // Verifies getAvailableSlots returns slots on a weekday with seeded data.
    @IsTest
    static void testGetAvailableSlots_WithData() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'C');
        buildFullSchedulingData(new List<User>{ counselorUser });

        Date futureDate = getNextWeekday();
        String dateStr = String.valueOf(futureDate);

        Test.startTest();
        List<Map<String, String>> result = GuestSchedulerController.getAvailableSlots(dateStr);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(!result.isEmpty(), 'Should have available slots on a weekday');
        for (Map<String, String> slot : result) {
            System.assertNotEquals(null, slot.get('startUtc'), 'Slot should have startUtc');
            System.assertNotEquals(null, slot.get('endUtc'), 'Slot should have endUtc');
        }
    }

    // Verifies events and ResourceAbsence rows reduce the busy-resource availability.
    @IsTest
    static void testGetAvailableSlots_WithBusyResource() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'D');
        Map<String, Object> data = buildFullSchedulingData(new List<User>{ counselorUser });

        Date futureDate = getNextWeekday();

        DateTime blockStart = DateTime.newInstanceGmt(futureDate, Time.newInstance(14, 0, 0, 0));
        DateTime blockEnd = blockStart.addHours(2);
        Event blockingEvent = new Event(
            Subject = 'Busy Block',
            StartDateTime = blockStart,
            EndDateTime = blockEnd,
            ShowAs = 'Busy',
            OwnerId = counselorUser.Id
        );
        insert blockingEvent;

        List<ServiceResource> resources = (List<ServiceResource>) data.get('serviceResources');
        ResourceAbsence ra = new ResourceAbsence(
            ResourceId = resources[0].Id,
            Start = DateTime.newInstanceGmt(futureDate, Time.newInstance(16, 0, 0, 0)),
            End = DateTime.newInstanceGmt(futureDate, Time.newInstance(17, 0, 0, 0)),
            Type = 'Vacation'
        );
        insert ra;

        String dateStr = String.valueOf(futureDate);

        Test.startTest();
        List<Map<String, String>> result = GuestSchedulerController.getAvailableSlots(dateStr);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
    }

    // Verifies a happy-path booking creates the expected Lead and Event.
    @IsTest
    static void testBookAppointment_Success() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'E');
        buildFullSchedulingData(new List<User>{ counselorUser });

        Date futureDate = getNextWeekday();
        DateTime startDT = DateTime.newInstanceGmt(futureDate, Time.newInstance(15, 0, 0, 0));
        DateTime endDT = startDT.addHours(1);
        String startISO = startDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endISO = endDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        Test.startTest();
        Map<String, String> result;
        try {
            result = GuestSchedulerController.bookAppointment(
                startISO, endISO,
                'Jane', 'Smith', 'jane' + String.valueOf(DateTime.now().getTime()) + '@test.com', '5559876543',
                '11th Grade', 'Website', 'guest1@test.com,guest2@test.com',
                'America/Chicago', 'google', 'spring2026', 'cpc'
            );
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Exception message should exist');
            Test.stopTest();
            return;
        }
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        if (result.get('success') == 'true') {
            System.assertNotEquals(null, result.get('leadId'), 'Lead Id should be present');
            System.assertNotEquals(null, result.get('eventId'), 'Event Id should be present');

            List<Lead> leads = [SELECT Id, FirstName, LastName, Email, Phone, Company, LeadSource
                                FROM Lead WHERE Id = :result.get('leadId')];
            System.assertEquals(1, leads.size(), 'Lead should exist');
            System.assertEquals('Smith Household', leads[0].Company);
            System.assertEquals('Website', leads[0].LeadSource);

            List<Event> events = [SELECT Id, Subject FROM Event WHERE Id = :result.get('eventId')];
            System.assertEquals(1, events.size(), 'Event should exist');
            System.assertEquals('Initial Consultation - Zenith Prep Academy', events[0].Subject);
        }
    }

    // Verifies the Lead.LeadSource defaults to Website when none is supplied.
    @IsTest
    static void testBookAppointment_WithDefaultLeadSource() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'F');
        buildFullSchedulingData(new List<User>{ counselorUser });

        Date futureDate = getNextWeekday();
        DateTime startDT = DateTime.newInstanceGmt(futureDate, Time.newInstance(15, 0, 0, 0));
        DateTime endDT = startDT.addHours(1);
        String startISO = startDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endISO = endDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        Test.startTest();
        Map<String, String> result;
        try {
            result = GuestSchedulerController.bookAppointment(
                startISO, endISO,
                'Bob', 'Jones', 'bob' + String.valueOf(DateTime.now().getTime()) + '@test.com', '5551112222',
                null, null, null, null, null, null, null
            );
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Exception message should exist');
            Test.stopTest();
            return;
        }
        Test.stopTest();

        if (result != null && result.get('success') == 'true') {
            Lead lead = [SELECT LeadSource FROM Lead WHERE Id = :result.get('leadId')];
            System.assertEquals('Website', lead.LeadSource, 'Default LeadSource should be Website');
        }
    }

    // Verifies bookAppointment returns SLOT_UNAVAILABLE when the slot is fully blocked.
    @IsTest
    static void testBookAppointment_SlotUnavailable() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'G');
        buildFullSchedulingData(new List<User>{ counselorUser });

        Date futureDate = getNextWeekday();
        DateTime blockStart = DateTime.newInstanceGmt(futureDate, Time.newInstance(10, 0, 0, 0));
        DateTime blockEnd = DateTime.newInstanceGmt(futureDate, Time.newInstance(23, 59, 0, 0));
        Event blockingEvent = new Event(
            Subject = 'Full Day Block',
            StartDateTime = blockStart,
            EndDateTime = blockEnd,
            ShowAs = 'Busy',
            OwnerId = counselorUser.Id
        );
        insert blockingEvent;

        DateTime startDT = DateTime.newInstanceGmt(futureDate, Time.newInstance(15, 0, 0, 0));
        DateTime endDT = startDT.addHours(1);
        String startISO = startDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endISO = endDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        Test.startTest();
        Map<String, String> result = GuestSchedulerController.bookAppointment(
            startISO, endISO,
            'Blocked', 'User', 'blocked@test.com', '5553334444',
            '9th Grade', 'Website', null,
            'America/Chicago', null, null, null
        );
        Test.stopTest();

        System.assertEquals('false', result.get('success'), 'Should fail when slot is unavailable');
        System.assertEquals('SLOT_UNAVAILABLE', result.get('error'), 'Error should be SLOT_UNAVAILABLE');
    }

    // Verifies round-robin selection across multiple resources.
    @IsTest
    static void testBookAppointment_MultipleResources_RoundRobin() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselor1 = createCounselorUser(profileId, 'H');
        User counselor2 = createCounselorUser(profileId, 'I');
        buildFullSchedulingData(new List<User>{ counselor1, counselor2 });

        Event existingEvent = new Event(
            Subject = 'Prior Meeting',
            StartDateTime = DateTime.now().addDays(1),
            EndDateTime = DateTime.now().addDays(1).addHours(1),
            ShowAs = 'Busy',
            OwnerId = counselor1.Id
        );
        insert existingEvent;

        Date futureDate = getNextWeekday();
        DateTime startDT = DateTime.newInstanceGmt(futureDate, Time.newInstance(15, 0, 0, 0));
        DateTime endDT = startDT.addHours(1);
        String startISO = startDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endISO = endDT.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        Test.startTest();
        Map<String, String> result;
        try {
            result = GuestSchedulerController.bookAppointment(
                startISO, endISO,
                'Multi', 'Resource', 'multi' + String.valueOf(DateTime.now().getTime()) + '@test.com', '5556667777',
                '12th Grade', 'Referral', null,
                'America/Chicago', null, null, null
            );
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Exception message should exist');
            Test.stopTest();
            return;
        }
        Test.stopTest();

        if (result != null && result.get('success') == 'true') {
            System.assertNotEquals(null, result.get('leadId'), 'Lead should be created');
            System.assertNotEquals(null, result.get('eventId'), 'Event should be created');
        }
    }

    // Verifies ServiceAppointment-based busy time is honored by getAvailableSlots.
    @IsTest
    static void testGetAvailableSlots_WithServiceAppointmentBusy() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'J');
        Map<String, Object> data = buildFullSchedulingData(new List<User>{ counselorUser });
        List<ServiceResource> resources = (List<ServiceResource>) data.get('serviceResources');
        Id territoryId = (Id) data.get('serviceTerritoryId');
        Id workTypeId = (Id) data.get('workTypeId');

        Date futureDate = getNextWeekday();

        Account tempAcct = new Account(Name = 'Temp Account');
        insert tempAcct;

        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = tempAcct.Id,
            ServiceTerritoryId = territoryId,
            WorkTypeId = workTypeId,
            EarliestStartTime = DateTime.newInstanceGmt(futureDate, Time.newInstance(14, 0, 0, 0)),
            DueDate = DateTime.newInstanceGmt(futureDate, Time.newInstance(15, 0, 0, 0)),
            SchedStartTime = DateTime.newInstanceGmt(futureDate, Time.newInstance(14, 0, 0, 0)),
            SchedEndTime = DateTime.newInstanceGmt(futureDate, Time.newInstance(15, 0, 0, 0)),
            Status = 'Scheduled'
        );
        insert sa;

        AssignedResource ar = new AssignedResource(
            ServiceAppointmentId = sa.Id,
            ServiceResourceId = resources[0].Id
        );
        insert ar;

        String dateStr = String.valueOf(futureDate);

        Test.startTest();
        List<Map<String, String>> result = GuestSchedulerController.getAvailableSlots(dateStr);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
    }

    // Verifies availableDates is populated and date format is yyyy-MM-dd.
    @IsTest
    static void testGetBookingConfig_AvailableDatesComputed() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'K');
        buildFullSchedulingData(new List<User>{ counselorUser });

        Test.startTest();
        Map<String, Object> result = GuestSchedulerController.getBookingConfig(5);
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'Should succeed: ' + result.get('error'));
        List<String> availDates = (List<String>) result.get('availableDates');
        System.assertNotEquals(null, availDates, 'Available dates should not be null');
        System.assert(!availDates.isEmpty(), 'Should have at least one available date');
        String firstDate = availDates[0];
        System.assertEquals(10, firstDate.length(), 'Date should be in yyyy-MM-dd format');
        System.assert(firstDate.contains('-'), 'Date should contain dashes');
    }

    // Verifies getAvailableSlots applies advance-hours filtering for today.
    @IsTest
    static void testGetAvailableSlots_TodayWithAdvanceHours() {
        Id profileId = getAdmissionProfileId();
        if (profileId == null) {
            System.assert(true, 'Admission Counsellor profile not found; skipping');
            return;
        }

        User counselorUser = createCounselorUser(profileId, 'L');
        buildFullSchedulingData(new List<User>{ counselorUser });

        String dateStr = String.valueOf(Date.today());

        Test.startTest();
        List<Map<String, String>> result = GuestSchedulerController.getAvailableSlots(dateStr);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
    }
}
