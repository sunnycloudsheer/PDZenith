public without sharing class SchedulingEmailSender {

    private static final String BOOKING_BASE_URL = 'https://site-enterprise-6958--dev2.sandbox.my.site.com/booking';
    private static final String LINK_PLACEHOLDER = '[[SCHEDULING_LINK]]';

    private static final Map<String, String> TEMPLATE_MAP = new Map<String, String>{
        'PD'  => 'PD_Scheduling_Email',
        'FSS' => 'FSS_Scheduling_Email'
    };

    public class EmailRequest {
        @InvocableVariable(required=true label='Contact Id')
        public Id contactId;

        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='Email Type (PD or FSS)')
        public String emailType;
    }

    public class EmailResult {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String errorMessage;
    }

    @InvocableMethod(
        label='Send Scheduling Email'
        description='Sends a PD or FSS scheduling email using an Email Template with a dynamic booking link'
        category='Scheduling'
    )
    public static List<EmailResult> sendSchedulingEmail(List<EmailRequest> requests) {
        List<EmailResult> results = new List<EmailResult>();

        // Bulk-collect Contact and Opportunity IDs
        Set<Id> contactIds = new Set<Id>();
        Set<Id> oppIds     = new Set<Id>();
        for (EmailRequest req : requests) {
            contactIds.add(req.contactId);
            oppIds.add(req.opportunityId);
        }

        Map<Id, Contact> contactMap = new Map<Id, Contact>([
            SELECT Id, FirstName, LastName, Name, Email
            FROM Contact WHERE Id IN :contactIds
        ]);
        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>([
            SELECT Id, Name, Account.Name
            FROM Opportunity WHERE Id IN :oppIds
        ]);

        for (EmailRequest req : requests) {
            EmailResult res = new EmailResult();
            try {
                String bType = (req.emailType != null) ? req.emailType.toUpperCase() : 'PD';
                String templateDevName = TEMPLATE_MAP.get(bType);
                if (templateDevName == null) {
                    throw new AuraHandledException('Unknown email type: ' + req.emailType);
                }

                List<EmailTemplate> templates = [
                    SELECT Id, Subject, HtmlValue, Body
                    FROM EmailTemplate
                    WHERE DeveloperName = :templateDevName
                    LIMIT 1
                ];
                if (templates.isEmpty()) {
                    throw new AuraHandledException(
                        'Email template "' + templateDevName + '" not found. '
                        + 'Please create it in Setup > Email Templates.');
                }

                Contact con = contactMap.get(req.contactId);
                Opportunity opp = oppMap.get(req.opportunityId);

                // Build the scheduling link with encrypted token
                String token = BookingTokenUtil.encrypt(req.contactId, req.opportunityId);
                String bookingLink = BOOKING_BASE_URL
                    + '?type=' + bType
                    + '&token=' + token;

                // Start from the raw template HTML and subject
                String htmlBody = templates[0].HtmlValue;
                String subject  = templates[0].Subject;
                String plainBody = templates[0].Body;

                // Replace merge fields manually
                if (con != null) {
                    htmlBody = replaceMerge(htmlBody, '{!Contact.FirstName}', con.FirstName);
                    htmlBody = replaceMerge(htmlBody, '{!Contact.LastName}', con.LastName);
                    htmlBody = replaceMerge(htmlBody, '{!Contact.Name}', con.Name);
                    subject  = replaceMerge(subject, '{!Contact.FirstName}', con.FirstName);
                    subject  = replaceMerge(subject, '{!Contact.LastName}', con.LastName);
                    subject  = replaceMerge(subject, '{!Contact.Name}', con.Name);
                    if (plainBody != null) {
                        plainBody = replaceMerge(plainBody, '{!Contact.FirstName}', con.FirstName);
                        plainBody = replaceMerge(plainBody, '{!Contact.LastName}', con.LastName);
                        plainBody = replaceMerge(plainBody, '{!Contact.Name}', con.Name);
                    }
                }
                if (opp != null) {
                    htmlBody = replaceMerge(htmlBody, '{!Opportunity.Name}', opp.Name);
                    subject  = replaceMerge(subject, '{!Opportunity.Name}', opp.Name);
                    if (opp.Account != null) {
                        htmlBody = replaceMerge(htmlBody, '{!Opportunity.Account.Name}', opp.Account.Name);
                    }
                }

                // Replace scheduling link placeholder
                htmlBody = htmlBody.replace(LINK_PLACEHOLDER, bookingLink);
                if (plainBody != null) {
                    plainBody = plainBody.replace(LINK_PLACEHOLDER, bookingLink);
                }

                // Build and send
                Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setTargetObjectId(req.contactId);
                mail.setWhatId(req.opportunityId);
                mail.setSubject(subject);
                mail.setHtmlBody(htmlBody);
                if (plainBody != null) {
                    mail.setPlainTextBody(plainBody);
                }
                mail.setSaveAsActivity(true);
                mail.setUseSignature(false);

                if (bType == 'FSS') {
                    mail.setCcAddresses(new List<String>{ 'fss@zenithprepacademy.com' });
                }

                Messaging.SendEmailResult[] sendResults = Messaging.sendEmail(
                    new List<Messaging.SingleEmailMessage>{ mail }
                );

                if (sendResults[0].isSuccess()) {
                    res.success = true;

                    // Stamp the scheduling link URL on the Opportunity
                    try {
                        Opportunity oppUpd = new Opportunity(Id = req.opportunityId);
                        if (bType == 'PD') {
                            oppUpd.PD_Scheduling_Link__c = bookingLink;
                        } else if (bType == 'FSS') {
                            oppUpd.FSS_Scheduling_Link__c = bookingLink;
                        }
                        update oppUpd;
                    } catch (Exception updEx) {
                        System.debug(LoggingLevel.WARN,
                            'Opportunity link update failed: ' + updEx.getMessage());
                    }
                } else {
                    res.success = false;
                    String errMsg = '';
                    for (Messaging.SendEmailError err : sendResults[0].getErrors()) {
                        errMsg += err.getMessage() + ' ';
                    }
                    res.errorMessage = errMsg.trim();
                }

            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    private static String replaceMerge(String source, String mergeField, String value) {
        if (source == null) return source;
        return source.replace(mergeField, (value != null) ? value : '');
    }
}
