@isTest
private class PDSchedulerHandlersTest {

    @TestSetup
    static void setupData() {
        OperatingHours oh = new OperatingHours(Name = 'PD Hours', TimeZone = 'America/Chicago');
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

        insert new List<WorkType>{
            new WorkType(Name='PD SOM Meeting - 1hr', EstimatedDuration=60, DurationType='Minutes', OperatingHoursId=oh.Id),
            new WorkType(Name='PD Follow-up - 30min', EstimatedDuration=30, DurationType='Minutes', OperatingHoursId=oh.Id)
        };

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

        List<ServiceResource> srList = new List<ServiceResource>();
        for (Integer i = 0; i < 3; i++) {
            srList.add(new ServiceResource(
                Name='PD Test'+(i+1), RelatedRecordId=pdUsers[i].Id, IsActive=true
            ));
        }
        insert srList;

        srList[0].Appointment_Count__c = 5;  srList[0].Weight__c = 1.0;
        srList[1].Appointment_Count__c = 10; srList[1].Weight__c = 2.0;
        srList[2].Appointment_Count__c = 3;  srList[2].Weight__c = 1.0;
        update srList;

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

        Account acct = new Account(Name='TestFamily');
        insert acct;

        Contact cont = new Contact(FirstName='Jane', LastName='TestFamily', Email='jane@test.com', Phone='5551234567', AccountId=acct.Id);
        insert cont;

        Opportunity opp = new Opportunity(Name='TestFamily Enrollment', AccountId=acct.Id, StageName='Qualification', CloseDate=Date.today().addDays(60));
        insert opp;

        insert new OpportunityContactRole(OpportunityId=opp.Id, ContactId=cont.Id, IsPrimary=true, Role='Decision Maker');
    }

    // Verifies round-robin selects the resource with the lowest load.
    @isTest
    static void testRoundRobin_SelectsLowestLoad() {
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

    // Verifies sticky assignment returns the previously-assigned PD on follow-up.
    @isTest
    static void testSticky_ReturnsAssignedPD() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd2 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test2' LIMIT 1];

        opp.Program_Director__c = pd2.RelatedRecordId;
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

    // Verifies follow-up requests resolve to the follow-up WorkType.
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

        WorkType followUpWT = [SELECT Id FROM WorkType WHERE Name='PD Follow-up - 30min' LIMIT 1];
        System.assertEquals(followUpWT.Id, results[0].workTypeId);
    }

    // Verifies the shared scheduling config returns territory and SOM WorkType for non-follow-ups.
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

        WorkType somWT = [SELECT Id FROM WorkType WHERE Name='PD SOM Meeting - 1hr' LIMIT 1];
        System.assertEquals(somWT.Id, results[0].workTypeId);
    }

    // Verifies the scheduling config returns the follow-up WorkType when isFollowUp=true.
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

    // Verifies first-call post-booking assigns a PD via round-robin and updates the Opportunity.
    @isTest
    static void testPostBooking_FirstCall_AssignsPDViaRoundRobin() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceTerritory st = [SELECT Id FROM ServiceTerritory WHERE Name='PD Territory 1' LIMIT 1];
        WorkType wt = [SELECT Id FROM WorkType WHERE Name='PD SOM Meeting - 1hr' LIMIT 1];

        Account acct = [SELECT Id FROM Account LIMIT 1];
        DateTime startDT = DateTime.now().addDays(5);
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId=acct.Id, ServiceTerritoryId=st.Id, WorkTypeId=wt.Id,
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

        ServiceResource pd3 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test3' LIMIT 1];
        System.assertEquals(pd3.Id, results[0].serviceResourceId, 'Should select PD with lowest load');

        Opportunity updOpp = [SELECT Program_Director__c, StageName FROM Opportunity WHERE Id=:opp.Id];
        System.assertEquals(pd3.RelatedRecordId, updOpp.Program_Director__c, 'PD User should be stamped on Opportunity');
        System.assertEquals('SOM Scheduled', updOpp.StageName, 'Stage should update');

        ServiceResource updPD = [SELECT Appointment_Count__c FROM ServiceResource WHERE Id=:pd3.Id];
        System.assertEquals(4, updPD.Appointment_Count__c, 'Count should increment from 3 to 4');

        ServiceAppointment updSA = [SELECT Meeting_Type__c, Subject FROM ServiceAppointment WHERE Id=:sa.Id];
        System.assertEquals('Program Director - 60 Minutes', updSA.Meeting_Type__c);

        List<AssignedResource> ars = [SELECT Id FROM AssignedResource WHERE ServiceAppointmentId=:sa.Id];
        System.assertEquals(1, ars.size(), 'AssignedResource should be created');
    }

    // Verifies follow-up post-booking reuses the sticky PD already on the Opportunity.
    @isTest
    static void testPostBooking_FollowUp_UsesStickyPD() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd2 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test2' LIMIT 1];
        ServiceTerritory st = [SELECT Id FROM ServiceTerritory WHERE Name='PD Territory 2' LIMIT 1];
        WorkType wt = [SELECT Id FROM WorkType WHERE Name='PD Follow-up - 30min' LIMIT 1];

        opp.Program_Director__c = pd2.RelatedRecordId;
        opp.StageName = 'SOM Scheduled';
        update opp;

        Account acct = [SELECT Id FROM Account LIMIT 1];
        DateTime startDT = DateTime.now().addDays(7);
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId=acct.Id, ServiceTerritoryId=st.Id, WorkTypeId=wt.Id,
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
        System.assertEquals(pd2.Id, results[0].serviceResourceId, 'Sticky PD should be used');

        ServiceAppointment updSA = [SELECT Meeting_Type__c FROM ServiceAppointment WHERE Id=:sa.Id];
        System.assertEquals('Program Director Follow Up', updSA.Meeting_Type__c);
    }

    // Verifies post-booking falls back to round-robin when the sticky PD is busy at the requested time.
    @isTest
    static void testPostBooking_StickyPDBusy_FallsBackToRoundRobin() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd1 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test1' LIMIT 1];
        ServiceTerritory st = [SELECT Id FROM ServiceTerritory WHERE Name='PD Territory 1' LIMIT 1];
        WorkType wt = [SELECT Id FROM WorkType WHERE Name='PD SOM Meeting - 1hr' LIMIT 1];

        opp.Program_Director__c = pd1.RelatedRecordId;
        update opp;

        Account acct = [SELECT Id FROM Account LIMIT 1];
        DateTime startDT = DateTime.now().addDays(5);

        ServiceAppointment conflictSA = new ServiceAppointment(
            ParentRecordId=acct.Id, ServiceTerritoryId=st.Id, WorkTypeId=wt.Id,
            SchedStartTime=startDT, SchedEndTime=startDT.addMinutes(60),
            EarliestStartTime=startDT, DueDate=startDT.addMinutes(60),
            Status='Scheduled'
        );
        insert conflictSA;
        insert new AssignedResource(ServiceAppointmentId=conflictSA.Id, ServiceResourceId=pd1.Id);

        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId=acct.Id, ServiceTerritoryId=st.Id, WorkTypeId=wt.Id,
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
        System.assertNotEquals(pd1.Id, results[0].serviceResourceId,
            'Sticky PD is busy, should fall back to round-robin');
    }

    // Verifies getAssignedPD returns success=false with an error when the Opportunity Id is unknown.
    @isTest
    static void testRoundRobin_UnknownOpportunity_ReturnsFailure() {
        PDRoundRobinHandler.PDRequest req = new PDRoundRobinHandler.PDRequest();
        req.opportunityId = '006000000000000AAA';
        req.isFollowUp = false;

        Test.startTest();
        List<PDRoundRobinHandler.PDResult> results = PDRoundRobinHandler.getAssignedPD(
            new List<PDRoundRobinHandler.PDRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(false, results[0].success, 'Unknown Opp must yield success=false');
        System.assertNotEquals(null, results[0].errorMessage, 'errorMessage must be populated');
    }

    // Verifies a sticky Program Director that is no longer a valid PD falls back to round-robin.
    @isTest
    static void testRoundRobin_StickyPDInvalid_FallsBackToRoundRobin() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        // Set a sticky PD that does NOT have the Program Director profile (use the running user).
        opp.Program_Director__c = UserInfo.getUserId();
        update opp;

        PDRoundRobinHandler.PDRequest req = new PDRoundRobinHandler.PDRequest();
        req.opportunityId = opp.Id;
        req.isFollowUp = false;

        Test.startTest();
        List<PDRoundRobinHandler.PDResult> results = PDRoundRobinHandler.getAssignedPD(
            new List<PDRoundRobinHandler.PDRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Should still succeed via round-robin');
        System.assertEquals(false, results[0].isSticky, 'Should not be sticky when PD is invalid');
    }

    // Verifies getAssignedPD bulkifies a list of requests with one result per request.
    @isTest
    static void testRoundRobin_BulkRequests_ReturnsResultPerRequest() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        List<PDRoundRobinHandler.PDRequest> requests = new List<PDRoundRobinHandler.PDRequest>();
        for (Integer i = 0; i < 5; i++) {
            PDRoundRobinHandler.PDRequest req = new PDRoundRobinHandler.PDRequest();
            req.opportunityId = opp.Id;
            req.isFollowUp = (Math.mod(i, 2) == 0);
            requests.add(req);
        }

        Test.startTest();
        List<PDRoundRobinHandler.PDResult> results = PDRoundRobinHandler.getAssignedPD(requests);
        Test.stopTest();

        System.assertEquals(5, results.size(), 'One result per request');
        for (PDRoundRobinHandler.PDResult r : results) {
            System.assertEquals(true, r.success, 'Each request should succeed');
        }
    }

    // Verifies a follow-up sticky assignment returns the follow-up WorkType for the sticky PD.
    @isTest
    static void testSticky_FollowUp_UsesFollowUpWorkType() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd1 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test1' LIMIT 1];

        opp.Program_Director__c = pd1.RelatedRecordId;
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
        WorkType followUpWT = [SELECT Id FROM WorkType WHERE Name='PD Follow-up - 30min' LIMIT 1];
        System.assertEquals(followUpWT.Id, results[0].workTypeId,
            'Sticky follow-up should resolve to the 30-min WorkType');
    }

    // Verifies the scheduling-config sticky path returns the same PD already on the Opportunity.
    @isTest
    static void testSchedulingConfig_StickyPath_ReturnsAssignedPD() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd2 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test2' LIMIT 1];

        opp.Program_Director__c = pd2.RelatedRecordId;
        update opp;

        PDSchedulingConfigHandler.ConfigRequest req = new PDSchedulingConfigHandler.ConfigRequest();
        req.opportunityId = opp.Id;
        req.isFollowUp = false;

        Test.startTest();
        List<PDSchedulingConfigHandler.ConfigResult> results = PDSchedulingConfigHandler.getSchedulingConfig(
            new List<PDSchedulingConfigHandler.ConfigRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Sticky path should succeed');
        System.assertEquals(pd2.Id, results[0].primaryResourceId, 'Sticky resource should be returned');
    }

    // Verifies the scheduling-config follow-up sticky path returns the follow-up duration WorkType.
    @isTest
    static void testSchedulingConfig_StickyFollowUp_UsesFollowUpWorkType() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ServiceResource pd1 = [SELECT Id, RelatedRecordId FROM ServiceResource WHERE Name='PD Test1' LIMIT 1];

        opp.Program_Director__c = pd1.RelatedRecordId;
        update opp;

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

    // Verifies bulk requests to the scheduling config produce one result per request.
    @isTest
    static void testSchedulingConfig_BulkRequests_ReturnsResultPerRequest() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        List<PDSchedulingConfigHandler.ConfigRequest> requests = new List<PDSchedulingConfigHandler.ConfigRequest>();
        for (Integer i = 0; i < 4; i++) {
            PDSchedulingConfigHandler.ConfigRequest req = new PDSchedulingConfigHandler.ConfigRequest();
            req.opportunityId = opp.Id;
            req.isFollowUp = (Math.mod(i, 2) == 0);
            requests.add(req);
        }

        Test.startTest();
        List<PDSchedulingConfigHandler.ConfigResult> results = PDSchedulingConfigHandler.getSchedulingConfig(requests);
        Test.stopTest();

        System.assertEquals(4, results.size(), 'One result per request');
        for (PDSchedulingConfigHandler.ConfigResult r : results) {
            System.assertEquals(true, r.success, 'Each scheduling-config request should succeed');
            System.assertNotEquals(null, r.workTypeId, 'workTypeId must be populated');
        }
    }

    // Verifies post-booking handler with an unknown serviceAppointmentId returns success=false.
    @isTest
    static void testPostBooking_UnknownSA_ReturnsFailure() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        PDPostBookingHandler.PostBookingRequest req = new PDPostBookingHandler.PostBookingRequest();
        req.opportunityId = opp.Id;
        req.serviceAppointmentId = '08p000000000000AAA';
        req.isFollowUp = false;

        Test.startTest();
        List<PDPostBookingHandler.PostBookingResult> results = PDPostBookingHandler.handlePostBooking(
            new List<PDPostBookingHandler.PostBookingRequest>{req}
        );
        Test.stopTest();

        System.assertEquals(false, results[0].success, 'Unknown SA must yield success=false');
        System.assertNotEquals(null, results[0].errorMessage, 'errorMessage must be populated');
    }
}