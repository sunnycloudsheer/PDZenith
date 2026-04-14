@isTest
private class PDSchedulerHandlersTest {

    @TestSetup
    static void setupData() {
        // Operating Hours
        OperatingHours oh = new OperatingHours(
            Name = 'PD Hours', TimeZone = 'America/Chicago'
        );
        insert oh;

        List<TimeSlot> slots = new List<TimeSlot>();
        for (String day : new List<String>{'Monday','Tuesday','Wednesday','Thursday','Friday'}) {
            slots.add(new TimeSlot(
                OperatingHoursId = oh.Id, DayOfWeek = day,
                StartTime = Time.newInstance(9,0,0,0),
                EndTime = Time.newInstance(17,0,0,0)
            ));
        }
        insert slots;

        // Work Types (exact names the handler expects)
        insert new List<WorkType>{
            new WorkType(Name='PD SOM Meeting - 1hr', EstimatedDuration=60, DurationType='Minutes', OperatingHoursId=oh.Id),
            new WorkType(Name='PD Follow-up - 30min', EstimatedDuration=30, DurationType='Minutes', OperatingHoursId=oh.Id)
        };

        // PD Users (must use Program Director profile for round-robin lookup)
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Program Director' LIMIT 1];
        List<User> pdUsers = new List<User>();
        for (Integer i = 1; i <= 3; i++) {
            pdUsers.add(new User(
                FirstName='PD', LastName='Test'+i,
                Email='pd'+i+'@zenith.test',
                Username='pd'+i+'@zenith.test.'+System.currentTimeMillis(),
                Alias='pd'+i, TimeZoneSidKey='America/Chicago',
                LocaleSidKey='en_US', EmailEncodingKey='UTF-8',
                ProfileId=p.Id, LanguageLocaleKey='en_US'
            ));
        }
        insert pdUsers;

        // Service Resources
        List<ServiceResource> srList = new List<ServiceResource>();
        for (Integer i = 0; i < 3; i++) {
            srList.add(new ServiceResource(
                Name='PD Test'+(i+1), RelatedRecordId=pdUsers[i].Id, IsActive=true
            ));
        }
        insert srList;

        // Set weights and appointment counts
        srList[0].Appointment_Count__c = 5; srList[0].Weight__c = 1.0;
        srList[1].Appointment_Count__c = 10; srList[1].Weight__c = 2.0;
        srList[2].Appointment_Count__c = 3; srList[2].Weight__c = 1.0;
        update srList;

        // Service Territories (one per PD)
        List<ServiceTerritory> territories = new List<ServiceTerritory>();
        for (Integer i = 0; i < 3; i++) {
            territories.add(new ServiceTerritory(Name='PD Territory '+(i+1), IsActive=true, OperatingHoursId=oh.Id));
        }
        insert territories;

        List<ServiceTerritoryMember> members = new List<ServiceTerritoryMember>();
        for (Integer i = 0; i < 3; i++) {
            members.add(new ServiceTerritoryMember(
                ServiceTerritoryId=territories[i].Id, ServiceResourceId=srList[i].Id,
                EffectiveStartDate=Date.today().addDays(-30)
            ));
        }
        insert members;

        // Account + Contact + Opportunity
        Account acct = new Account(Name='TestFamily');
        insert acct;

        Contact cont = new Contact(FirstName='Jane',LastName='TestFamily',Email='jane@test.com',Phone='5551234567',AccountId=acct.Id);
        insert cont;

        Opportunity opp = new Opportunity(Name='TestFamily Enrollment',AccountId=acct.Id,StageName='Qualification',CloseDate=Date.today().addDays(60));
        insert opp;

        insert new OpportunityContactRole(OpportunityId=opp.Id,ContactId=cont.Id,IsPrimary=true,Role='Decision Maker');
    }

    // ═══ ROUND ROBIN TESTS (PDRoundRobinHandler — still used for reference/validation) ═══

    @isTest
    static void testRoundRobin_SelectsLowestLoad() {
        // PD1: 5/1.0=5.0, PD2: 10/2.0=5.0, PD3: 3/1.0=3.0 ← lowest
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        PDRoundRobinHandler.PDRequest req = new PDRoundRobinHandler.PDRequest();
        req.opportunityId = opp.Id;
        req.isFollowUp = false;

        Test.startTest();
        List<PDRoundRobinHandler.PDResult> results = PDRoundRobinHandler.getAssignedPD(
            new List<PDRoundRobinHandler.PDRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        System.assertEquals(false, results[0].isSticky);
        System.assertNotEquals(null, results[0].serviceResourceId);
        System.assertNotEquals(null, results[0].serviceTerritoryId);
        System.assertNotEquals(null, results[0].workTypeId);
    }

    @isTest
    static void testSticky_ReturnsAssignedPD() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd2 = [SELECT Id FROM ServiceResource WHERE Name='PD Test2' LIMIT 1];

        // Stamp sticky PD
        opp.Assigned_PD__c = pd2.Id;
        update opp;

        PDRoundRobinHandler.PDRequest req = new PDRoundRobinHandler.PDRequest();
        req.opportunityId = opp.Id;
        req.isFollowUp = true;

        Test.startTest();
        List<PDRoundRobinHandler.PDResult> results = PDRoundRobinHandler.getAssignedPD(
            new List<PDRoundRobinHandler.PDRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        System.assertEquals(true, results[0].isSticky);
        System.assertEquals(pd2.Id, results[0].serviceResourceId);
    }

    @isTest
    static void testRoundRobin_FollowUpWorkType() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        PDRoundRobinHandler.PDRequest req = new PDRoundRobinHandler.PDRequest();
        req.opportunityId = opp.Id;
        req.isFollowUp = true;

        Test.startTest();
        List<PDRoundRobinHandler.PDResult> results = PDRoundRobinHandler.getAssignedPD(
            new List<PDRoundRobinHandler.PDRequest>{req}
        );
        Test.stopTest();

        // Verify follow-up work type was selected
        WorkType followUpWT = [SELECT Id FROM WorkType WHERE Name='PD Follow-up - 30min' LIMIT 1];
        System.assertEquals(followUpWT.Id, results[0].workTypeId);
    }

    // ═══ SCHEDULING CONFIG TESTS (PDSchedulingConfigHandler) ═══

    @isTest
    static void testSchedulingConfig_ReturnsSharedConfig() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        PDSchedulingConfigHandler.ConfigRequest req = new PDSchedulingConfigHandler.ConfigRequest();
        req.opportunityId = opp.Id;
        req.isFollowUp = false;

        Test.startTest();
        List<PDSchedulingConfigHandler.ConfigResult> results = PDSchedulingConfigHandler.getSchedulingConfig(
            new List<PDSchedulingConfigHandler.ConfigRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        System.assertNotEquals(null, results[0].serviceTerritoryId, 'Should return a territory');
        System.assertNotEquals(null, results[0].workTypeId, 'Should return a work type');

        // Verify the work type is the 60-min version (not follow-up)
        WorkType somWT = [SELECT Id FROM WorkType WHERE Name='PD SOM Meeting - 1hr' LIMIT 1];
        System.assertEquals(somWT.Id, results[0].workTypeId);
    }

    @isTest
    static void testSchedulingConfig_FollowUp() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        PDSchedulingConfigHandler.ConfigRequest req = new PDSchedulingConfigHandler.ConfigRequest();
        req.opportunityId = opp.Id;
        req.isFollowUp = true;

        Test.startTest();
        List<PDSchedulingConfigHandler.ConfigResult> results = PDSchedulingConfigHandler.getSchedulingConfig(
            new List<PDSchedulingConfigHandler.ConfigRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        WorkType followUpWT = [SELECT Id FROM WorkType WHERE Name='PD Follow-up - 30min' LIMIT 1];
        System.assertEquals(followUpWT.Id, results[0].workTypeId);
    }

    // ═══ POST-BOOKING TESTS (PDPostBookingHandler — new round-robin + AR + Event logic) ═══

    @isTest
    static void testPostBooking_FirstCall_AssignsPDViaRoundRobin() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceTerritory st = [SELECT Id FROM ServiceTerritory WHERE Name='PD Territory 1' LIMIT 1];
        WorkType wt = [SELECT Id FROM WorkType WHERE Name='PD SOM Meeting - 1hr' LIMIT 1];

        // Create SA (simulating what the flow does before calling PostBookingHandler)
        Contact cont = [SELECT Id FROM Contact LIMIT 1];
        DateTime startDT = DateTime.now().addDays(5);
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId=cont.Id, ServiceTerritoryId=st.Id, WorkTypeId=wt.Id,
            SchedStartTime=startDT, SchedEndTime=startDT.addMinutes(60),
            EarliestStartTime=startDT, DueDate=startDT.addMinutes(60),
            Status='Scheduled', Email='jane@test.com', Phone='5551234567'
        );
        insert sa;

        PDPostBookingHandler.PostBookingRequest req = new PDPostBookingHandler.PostBookingRequest();
        req.opportunityId = opp.Id;
        req.serviceAppointmentId = sa.Id;
        req.isFollowUp = false;

        Test.startTest();
        List<PDPostBookingHandler.PostBookingResult> results = PDPostBookingHandler.handlePostBooking(
            new List<PDPostBookingHandler.PostBookingRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Post-booking should succeed');
        System.assertNotEquals(null, results[0].pdName, 'Should return PD name');
        System.assertNotEquals(null, results[0].pdUserId, 'Should return PD user Id');
        System.assertNotEquals(null, results[0].serviceResourceId, 'Should return PD resource Id');

        // Verify PD3 was selected (lowest load: 3/1.0=3.0)
        ServiceResource pd3 = [SELECT Id FROM ServiceResource WHERE Name='PD Test3' LIMIT 1];
        System.assertEquals(pd3.Id, results[0].serviceResourceId, 'Should select PD with lowest load');

        // Verify Opp stamped
        Opportunity updOpp = [SELECT Assigned_PD__c, StageName FROM Opportunity WHERE Id=:opp.Id];
        System.assertEquals(pd3.Id, updOpp.Assigned_PD__c, 'PD should be stamped on Opportunity');
        System.assertEquals('SOM Scheduled', updOpp.StageName, 'Stage should update');

        // Verify count incremented
        ServiceResource updPD = [SELECT Appointment_Count__c FROM ServiceResource WHERE Id=:pd3.Id];
        System.assertEquals(4, updPD.Appointment_Count__c, 'Count should increment from 3 to 4');

        // Verify SA updated
        ServiceAppointment updSA = [SELECT Meeting_Type__c, Subject FROM ServiceAppointment WHERE Id=:sa.Id];
        System.assertEquals('Program Director - 60 Minutes', updSA.Meeting_Type__c);

        // Verify AssignedResource created
        List<AssignedResource> ars = [SELECT Id FROM AssignedResource WHERE ServiceAppointmentId=:sa.Id];
        System.assertEquals(1, ars.size(), 'AssignedResource should be created');
    }

    @isTest
    static void testPostBooking_FollowUp_UsesStickyPD() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd2 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test2' LIMIT 1];
        ServiceTerritory st = [SELECT Id FROM ServiceTerritory WHERE Name='PD Territory 2' LIMIT 1];
        WorkType wt = [SELECT Id FROM WorkType WHERE Name='PD Follow-up - 30min' LIMIT 1];

        // Pre-stamp sticky PD
        opp.Assigned_PD__c = pd2.Id;
        opp.StageName = 'SOM Scheduled';
        update opp;

        Contact cont = [SELECT Id FROM Contact LIMIT 1];
        DateTime startDT = DateTime.now().addDays(7);
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId=cont.Id, ServiceTerritoryId=st.Id, WorkTypeId=wt.Id,
            SchedStartTime=startDT, SchedEndTime=startDT.addMinutes(30),
            EarliestStartTime=startDT, DueDate=startDT.addMinutes(30),
            Status='Scheduled', Email='jane@test.com'
        );
        insert sa;

        PDPostBookingHandler.PostBookingRequest req = new PDPostBookingHandler.PostBookingRequest();
        req.opportunityId = opp.Id;
        req.serviceAppointmentId = sa.Id;
        req.isFollowUp = true;

        Test.startTest();
        List<PDPostBookingHandler.PostBookingResult> results = PDPostBookingHandler.handlePostBooking(
            new List<PDPostBookingHandler.PostBookingRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        // Sticky PD should be used (PD2)
        System.assertEquals(pd2.Id, results[0].serviceResourceId, 'Sticky PD should be used');

        ServiceAppointment updSA = [SELECT Meeting_Type__c FROM ServiceAppointment WHERE Id=:sa.Id];
        System.assertEquals('Program Director Follow Up', updSA.Meeting_Type__c);
    }

    @isTest
    static void testPostBooking_StickyPDBusy_FallsBackToRoundRobin() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd1 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test1' LIMIT 1];
        ServiceTerritory st = [SELECT Id FROM ServiceTerritory WHERE Name='PD Territory 1' LIMIT 1];
        WorkType wt = [SELECT Id FROM WorkType WHERE Name='PD SOM Meeting - 1hr' LIMIT 1];

        // Pre-stamp sticky PD1
        opp.Assigned_PD__c = pd1.Id;
        update opp;

        Contact cont = [SELECT Id FROM Contact LIMIT 1];
        DateTime startDT = DateTime.now().addDays(5);

        // Create a conflicting appointment for PD1 at the same time
        ServiceAppointment conflictSA = new ServiceAppointment(
            ParentRecordId=cont.Id, ServiceTerritoryId=st.Id, WorkTypeId=wt.Id,
            SchedStartTime=startDT, SchedEndTime=startDT.addMinutes(60),
            EarliestStartTime=startDT, DueDate=startDT.addMinutes(60),
            Status='Scheduled'
        );
        insert conflictSA;
        insert new AssignedResource(ServiceAppointmentId=conflictSA.Id, ServiceResourceId=pd1.Id);

        // Now create the SA we want to book
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId=cont.Id, ServiceTerritoryId=st.Id, WorkTypeId=wt.Id,
            SchedStartTime=startDT, SchedEndTime=startDT.addMinutes(60),
            EarliestStartTime=startDT, DueDate=startDT.addMinutes(60),
            Status='Scheduled', Email='jane@test.com'
        );
        insert sa;

        PDPostBookingHandler.PostBookingRequest req = new PDPostBookingHandler.PostBookingRequest();
        req.opportunityId = opp.Id;
        req.serviceAppointmentId = sa.Id;
        req.isFollowUp = false;

        Test.startTest();
        List<PDPostBookingHandler.PostBookingResult> results = PDPostBookingHandler.handlePostBooking(
            new List<PDPostBookingHandler.PostBookingRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        // Should NOT be PD1 (busy) — should fall back to round-robin
        System.assertNotEquals(pd1.Id, results[0].serviceResourceId,
            'Sticky PD is busy, should fall back to round-robin');
    }
}
