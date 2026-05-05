@IsTest
private class LeadAutoConvertQueueableTest {

    private static Lead insertReadyToConvertLead() {
        LeadAutoConvert.bypassTrigger = true;
        Lead l = new Lead(
            FirstName = 'Pat',
            LastName  = 'Parent',
            Company   = 'Parent Household',
            Email     = 'pat@example.com',
            Phone     = '5555550000',
            Status    = LeadAutoConvert.QUALIFIED_STATUS,
            No_of_Student_Enrolling_Today__c = '1',
            Parent_1_Name_First_Last__c = 'Pat Parent',
            Student_Name__c = 'Alex Kid',
            Student_Email__c = 'alex@example.com'
        );
        insert l;
        LeadAutoConvert.bypassTrigger = false;
        return l;
    }

    // Verifies the queueable runs the convert service and flips IsConverted.
    @IsTest
    static void execute_convertsLeadViaUnderlyingService() {
        Lead l = insertReadyToConvertLead();

        Test.startTest();
        System.enqueueJob(new LeadAutoConvertQueueable(new Set<Id>{ l.Id }));
        Test.stopTest();

        Lead refreshed = [
            SELECT IsConverted, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId
            FROM Lead WHERE Id = :l.Id
        ];
        System.assertEquals(true, refreshed.IsConverted,
            'Queueable.execute should run the convert service and flip IsConverted.');
        System.assertNotEquals(null, refreshed.ConvertedAccountId,
            'Converted Account should be populated.');
        System.assertNotEquals(null, refreshed.ConvertedContactId,
            'Converted Contact should be populated.');
        System.assertNotEquals(null, refreshed.ConvertedOpportunityId,
            'Converted Opportunity should be populated.');
    }

    // Verifies enqueueJob actually schedules exactly one queueable run.
    @IsTest
    static void enqueue_schedulesAsyncJob() {
        Lead l = insertReadyToConvertLead();
        Integer queuedBefore = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];

        Test.startTest();
        System.enqueueJob(new LeadAutoConvertQueueable(new Set<Id>{ l.Id }));
        Integer queuedDuringTest = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];
        Test.stopTest();

        System.assertEquals(queuedBefore + 1, queuedDuringTest,
            'Exactly one queueable job should be scheduled by enqueueJob.');
    }

    // Verifies an empty Id set is a no-op and creates no records.
    @IsTest
    static void execute_emptyIdSet_isNoOp() {
        Integer accountsBefore = [SELECT COUNT() FROM Account];
        Integer contactsBefore = [SELECT COUNT() FROM Contact];
        Integer oppsBefore     = [SELECT COUNT() FROM Opportunity];

        Test.startTest();
        System.enqueueJob(new LeadAutoConvertQueueable(new Set<Id>()));
        Test.stopTest();

        System.assertEquals(accountsBefore, [SELECT COUNT() FROM Account],
            'Empty Id set must not create Accounts.');
        System.assertEquals(contactsBefore, [SELECT COUNT() FROM Contact],
            'Empty Id set must not create Contacts.');
        System.assertEquals(oppsBefore, [SELECT COUNT() FROM Opportunity],
            'Empty Id set must not create Opportunities.');
    }

    // Verifies a null Id set is tolerated without side effects.
    @IsTest
    static void execute_nullIdSet_isNoOp() {
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        Test.startTest();
        System.enqueueJob(new LeadAutoConvertQueueable(null));
        Test.stopTest();

        System.assertEquals(accountsBefore, [SELECT COUNT() FROM Account],
            'Null Id set must be tolerated without side effects.');
    }

}
