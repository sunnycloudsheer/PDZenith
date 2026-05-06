@isTest
private class LeadICEmailSenderTest {

    private static final String TEMPLATE_DEV_NAME = 'IC_Scheduling_Email_1778061283900';

    @TestSetup
    static void setupData() {
        Folder f = [SELECT Id FROM Folder WHERE Type = 'Email' AND DeveloperName = 'Scheduling_Templates' LIMIT 1];
        List<EmailTemplate> existing = [
            SELECT Id FROM EmailTemplate WHERE DeveloperName = :TEMPLATE_DEV_NAME LIMIT 1
        ];
        if (existing.isEmpty()) {
            insert new EmailTemplate(
                Name = 'IC Scheduling Link Send Email',
                DeveloperName = TEMPLATE_DEV_NAME,
                FolderId = f.Id,
                TemplateType = 'custom',
                Subject = 'Schedule Your Initial Consultation with Zenith Prep Academy',
                HtmlValue = '<p>Hi {{{Recipient.FirstName}}} {{{Recipient.LastName}}},</p><p><a href="{{{Recipient.IC_Schedule_Link__c}}}">Schedule</a></p>',
                Body = 'Hi {{{Recipient.FirstName}}} {{{Recipient.LastName}}}, click {{{Recipient.IC_Schedule_Link__c}}} to schedule.',
                IsActive = true
            );
        }

        insert new List<Lead>{
            new Lead(
                FirstName = 'Happy', LastName = 'Path',
                Company = 'Test Co', Status = 'New',
                Email = 'happy@example.com',
                IC_Schedule_Link__c = 'https://test.salesforce.com/booking?type=IC&action=schedule&token=happy'
            ),
            new Lead(
                FirstName = 'No', LastName = 'Email',
                Company = 'Test Co', Status = 'New',
                IC_Schedule_Link__c = 'https://test.salesforce.com/booking?type=IC&action=schedule&token=noemail'
            ),
            new Lead(
                FirstName = 'No', LastName = 'Link',
                Company = 'Test Co', Status = 'New',
                Email = 'nolink@example.com'
            )
        };

        // Force-clear the auto-stamped IC link on the "No Link" Lead. The
        // Lead_Generate_IC_Schedule_Token flow fires on insert and stamps a
        // link; we need the field genuinely blank for this test scenario.
        List<Lead> noLinkLeads = [
            SELECT Id FROM Lead WHERE FirstName = 'No' AND LastName = 'Link'
        ];
        for (Lead nl : noLinkLeads) {
            nl.IC_Schedule_Link__c = null;
            nl.IC_Schedule_Token__c = null;
        }
        update noLinkLeads;
    }

    // Verifies the happy path returns success=true for a Lead with both Email and IC link.
    @isTest
    static void happyPath_sendsEmail() {
        Lead happy = [SELECT Id FROM Lead WHERE FirstName = 'Happy' LIMIT 1];
        LeadICEmailSender.LeadICRequest req = new LeadICEmailSender.LeadICRequest();
        req.leadId = happy.Id;

        Test.startTest();
        List<LeadICEmailSender.LeadICResult> out =
            LeadICEmailSender.sendICEmailToLead(new List<LeadICEmailSender.LeadICRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].success,
            'Happy path expected success=true, got error: ' + out[0].errorMessage);
    }

    // Verifies a Lead missing Email returns success=false with an error message.
    @isTest
    static void leadWithNoEmail_returnsErrorResult() {
        Lead noEmailLead = [SELECT Id FROM Lead WHERE FirstName = 'No' AND LastName = 'Email' LIMIT 1];
        LeadICEmailSender.LeadICRequest req = new LeadICEmailSender.LeadICRequest();
        req.leadId = noEmailLead.Id;

        Test.startTest();
        List<LeadICEmailSender.LeadICResult> out =
            LeadICEmailSender.sendICEmailToLead(new List<LeadICEmailSender.LeadICRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(false, out[0].success,
            'Lead without Email must return success=false');
        System.assertNotEquals(null, out[0].errorMessage,
            'Error message must be populated when send fails');
    }

    // Verifies a Lead missing the IC link returns success=false with an error message.
    @isTest
    static void leadWithNoLink_returnsErrorResult() {
        Lead noLinkLead = [SELECT Id FROM Lead WHERE FirstName = 'No' AND LastName = 'Link' LIMIT 1];
        LeadICEmailSender.LeadICRequest req = new LeadICEmailSender.LeadICRequest();
        req.leadId = noLinkLead.Id;

        Test.startTest();
        List<LeadICEmailSender.LeadICResult> out =
            LeadICEmailSender.sendICEmailToLead(new List<LeadICEmailSender.LeadICRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(false, out[0].success,
            'Lead without IC Schedule Link must return success=false');
        System.assertNotEquals(null, out[0].errorMessage,
            'Error message must be populated when send fails');
    }

    // Verifies an unknown Lead Id returns success=false.
    @isTest
    static void unknownLeadId_returnsErrorResult() {
        LeadICEmailSender.LeadICRequest req = new LeadICEmailSender.LeadICRequest();
        req.leadId = '00Q000000000001AAA';

        Test.startTest();
        List<LeadICEmailSender.LeadICResult> out =
            LeadICEmailSender.sendICEmailToLead(new List<LeadICEmailSender.LeadICRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(false, out[0].success,
            'Unknown Lead Id must return success=false');
    }

    // Verifies an empty input list returns an empty result list.
    @isTest
    static void emptyInput_returnsEmptyList() {
        Test.startTest();
        List<LeadICEmailSender.LeadICResult> out =
            LeadICEmailSender.sendICEmailToLead(new List<LeadICEmailSender.LeadICRequest>());
        Test.stopTest();
        System.assertEquals(0, out.size());
    }
}
