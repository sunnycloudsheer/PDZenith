// Sends the IC scheduling email to a Lead using a Lightning Email Template; merge fields render natively from Lead context.
public without sharing class LeadICEmailSender {

    private static final String TEMPLATE_DEV_NAME = 'IC_Scheduling_Link_Send_Email';

    public class LeadICRequest {
        @InvocableVariable(required=true label='Lead Id')
        public Id leadId;
    }

    public class LeadICResult {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String  errorMessage;
    }

    @InvocableMethod(
        label='Send IC Scheduling Email to Lead'
        description='Sends the IC scheduling email to a Lead using the IC Scheduling Link Send Email Lightning template; the link is read from Lead.IC_Schedule_Link__c via {{{Recipient.IC_Schedule_Link__c}}}.'
        category='Scheduling'
    )
    public static List<LeadICResult> sendICEmailToLead(List<LeadICRequest> requests) {
        List<LeadICResult> results = new List<LeadICResult>();

        Set<Id> leadIds = new Set<Id>();
        for (LeadICRequest req : requests) leadIds.add(req.leadId);

        Map<Id, Lead> leadMap = new Map<Id, Lead>([
            SELECT Id, Email, IC_Schedule_Link__c
            FROM Lead WHERE Id IN :leadIds
        ]);

        EmailTemplate tmpl;
        for (EmailTemplate et : [
            SELECT Id, DeveloperName
            FROM EmailTemplate
            WHERE DeveloperName = :TEMPLATE_DEV_NAME
            LIMIT 1
        ]) {
            tmpl = et;
        }

        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
        List<Integer> emailToResultIndex = new List<Integer>();

        for (Integer i = 0; i < requests.size(); i++) {
            LeadICRequest req = requests[i];
            LeadICResult res = new LeadICResult();
            try {
                if (tmpl == null) {
                    throw new AuraHandledException(
                        'Email template "' + TEMPLATE_DEV_NAME + '" not found. Please create it in Setup > Email Templates.');
                }
                Lead ld = leadMap.get(req.leadId);
                if (ld == null) throw new AuraHandledException('Lead not found: ' + req.leadId);
                if (String.isBlank(ld.Email)) throw new AuraHandledException('Lead has no Email.');
                if (String.isBlank(ld.IC_Schedule_Link__c)) {
                    throw new AuraHandledException('IC Schedule Link is not yet generated on this Lead.');
                }

                Messaging.SingleEmailMessage mail = Messaging.renderStoredEmailTemplate(
                    tmpl.Id, req.leadId, null
                );
                mail.setTargetObjectId(req.leadId);
                mail.setSaveAsActivity(true);
                mail.setUseSignature(false);
                mail.setTreatTargetObjectAsRecipient(true);

                emailsToSend.add(mail);
                emailToResultIndex.add(i);
                res.success = true;
            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }

        if (!emailsToSend.isEmpty()) {
            try {
                Messaging.SendEmailResult[] sendResults = Messaging.sendEmail(emailsToSend);
                for (Integer j = 0; j < sendResults.size(); j++) {
                    Integer resultIdx = emailToResultIndex[j];
                    if (!sendResults[j].isSuccess()) {
                        results[resultIdx].success = false;
                        String errMsg = '';
                        for (Messaging.SendEmailError err : sendResults[j].getErrors()) {
                            errMsg += err.getMessage() + ' ';
                        }
                        results[resultIdx].errorMessage = errMsg.trim();
                    }
                }
            } catch (Exception ex) {
                for (Integer idx : emailToResultIndex) {
                    results[idx].success = false;
                    results[idx].errorMessage = 'Email send failed: ' + ex.getMessage();
                }
            }
        }

        return results;
    }
}
