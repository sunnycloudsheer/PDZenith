/**
 * Tests for LeadAutoConvertQueueable.
 *
 * The queueable is a thin async wrapper around LeadAutoConvert.convertLeads —
 * the service layer is exercised in depth by LeadAutoConvertTest, so these
 * tests focus on the wrapper's own contract: that enqueuing actually runs the
 * conversion, and that defensive inputs (null / empty) don't blow up.
 */
@IsTest
private class LeadAutoConvertQueueableTest {

    private static Lead insertReadyToConvertLead() {
        // Bypass the trigger during seed insert so we can choose when
        // conversion fires — here it's the queueable, not the trigger.
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

    @IsTest
    static void enqueue_schedulesAsyncJob() {
        // Verifies the queueable is actually queued (and only one) — separate
        // from the conversion outcome so we catch regressions in trigger /
        // service wiring that double-enqueue.
        Lead l = insertReadyToConvertLead();
        Integer queuedBefore = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];

        Test.startTest();
        System.enqueueJob(new LeadAutoConvertQueueable(new Set<Id>{ l.Id }));
        Integer queuedDuringTest = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];
        Test.stopTest();

        System.assertEquals(queuedBefore + 1, queuedDuringTest,
            'Exactly one queueable job should be scheduled by enqueueJob.');
    }

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
