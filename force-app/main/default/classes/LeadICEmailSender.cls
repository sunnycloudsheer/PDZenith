// Sends the IC scheduling email to a Lead using the IC_Scheduling_Email template and the link stamped on Lead.IC_Schedule_Link__c.
public without sharing class LeadICEmailSender {

    private static final String LINK_PLACEHOLDER = '[[SCHEDULING_LINK]]';
    private static final String TEMPLATE_DEV_NAME = 'IC_Scheduling_Email';

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
        description='Sends the IC scheduling email to a Lead using the IC_Scheduling_Email template with the link already stamped on Lead.IC_Schedule_Link__c'
        category='Scheduling'
    )
    public static List<LeadICResult> sendICEmailToLead(List<LeadICRequest> requests) {
        List<LeadICResult> results = new List<LeadICResult>();

        Set<Id> leadIds = new Set<Id>();
        for (LeadICRequest req : requests) leadIds.add(req.leadId);

        Map<Id, Lead> leadMap = new Map<Id, Lead>([
            SELECT Id, FirstName, LastName, Name, Email, IC_Schedule_Link__c
            FROM Lead WHERE Id IN :leadIds
        ]);

        EmailTemplate tmpl;
        for (EmailTemplate et : [
            SELECT Id, DeveloperName, Subject, HtmlValue, Body
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

                String htmlBody  = tmpl.HtmlValue;
                String subject   = tmpl.Subject;
                String plainBody = tmpl.Body;

                htmlBody  = replaceMerge(htmlBody, '{!Lead.FirstName}', ld.FirstName);
                htmlBody  = replaceMerge(htmlBody, '{!Lead.LastName}',  ld.LastName);
                htmlBody  = replaceMerge(htmlBody, '{!Lead.Name}',      ld.Name);
                subject   = replaceMerge(subject,  '{!Lead.FirstName}', ld.FirstName);
                subject   = replaceMerge(subject,  '{!Lead.LastName}',  ld.LastName);
                subject   = replaceMerge(subject,  '{!Lead.Name}',      ld.Name);
                if (plainBody != null) {
                    plainBody = replaceMerge(plainBody, '{!Lead.FirstName}', ld.FirstName);
                    plainBody = replaceMerge(plainBody, '{!Lead.LastName}',  ld.LastName);
                    plainBody = replaceMerge(plainBody, '{!Lead.Name}',      ld.Name);
                }

                htmlBody = htmlBody.replace(LINK_PLACEHOLDER, ld.IC_Schedule_Link__c);
                if (plainBody != null) {
                    plainBody = plainBody.replace(LINK_PLACEHOLDER, ld.IC_Schedule_Link__c);
                }

                Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setTargetObjectId(req.leadId);
                mail.setSubject(subject);
                mail.setHtmlBody(htmlBody);
                if (plainBody != null) mail.setPlainTextBody(plainBody);
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

    // Null-safe merge-field replacement.
    private static String replaceMerge(String source, String mergeField, String value) {
        if (source == null) return source;
        return source.replace(mergeField, (value != null) ? value : '');
    }
}
