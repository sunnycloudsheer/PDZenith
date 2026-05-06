public without sharing class SchedulingEmailSender {

    // PRODUCTION: replace with the production Experience Cloud booking URL before deploy.
    private static final String BOOKING_BASE_URL =
        'https://site-enterprise-6958--dev2.sandbox.my.site.com/booking';

    // FSS shared inbox CC'd on every FSS scheduling email.
    private static final String FSS_CC_ADDRESS = 'fss@zenithprepacademy.com';

    private static final Map<String, String> TEMPLATE_MAP = new Map<String, String>{
        'PD'  => 'PD_Scheduling_Link_Send_Email_1778062406702',
        'FSS' => 'FSS_Scheduling_Link_Send_Email_1778065360225'
    };

    public class EmailRequest {
        @InvocableVariable(required=true label='Contact Id')
        public Id contactId;

        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='Email Type (PD or FSS)')
        public String emailType;

        @InvocableVariable(label='Skip Email (generate link only)')
        public Boolean skipEmail;
    }

    public class EmailResult {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String errorMessage;
    }

    // Sends a PD or FSS scheduling email (or generates the link only) using a Lightning Email Template; the booking link is read by the template from Opportunity.PD_Scheduling_Link__c / FSS_Scheduling_Link__c.
    @InvocableMethod(
        label='Send Scheduling Email'
        description='Sends a PD or FSS scheduling email rendered from a Lightning Email Template, or generates and stamps the link only.'
        category='Scheduling'
    )
    public static List<EmailResult> sendSchedulingEmail(List<EmailRequest> requests) {
        List<EmailResult> results = new List<EmailResult>();

        Set<Id> contactIds = new Set<Id>();
        Set<Id> oppIds     = new Set<Id>();
        Set<String> templateDevNames = new Set<String>();
        for (EmailRequest req : requests) {
            contactIds.add(req.contactId);
            oppIds.add(req.opportunityId);
            String bType = (req.emailType != null) ? req.emailType.toUpperCase() : 'PD';
            String devName = TEMPLATE_MAP.get(bType);
            if (devName != null) {
                templateDevNames.add(devName);
            }
        }

        Map<Id, Contact> contactMap = new Map<Id, Contact>([
            SELECT Id, Email
            FROM Contact WHERE Id IN :contactIds
        ]);
        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>([
            SELECT Id, StageName, PD_Scheduling_Link__c, FSS_Scheduling_Link__c
            FROM Opportunity WHERE Id IN :oppIds
        ]);

        Map<String, EmailTemplate> templateCache = new Map<String, EmailTemplate>();
        for (EmailTemplate et : [
            SELECT Id, DeveloperName
            FROM EmailTemplate
            WHERE DeveloperName IN :templateDevNames
        ]) {
            templateCache.put(et.DeveloperName, et);
        }

        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
        Map<Integer, Opportunity> oppsByRequestIndex = new Map<Integer, Opportunity>();
        List<Integer> emailToResultIndex = new List<Integer>();

        for (Integer i = 0; i < requests.size(); i++) {
            EmailRequest req = requests[i];
            EmailResult res = new EmailResult();
            Boolean skipEmail = (req.skipEmail != null && req.skipEmail);
            try {
                String bType = (req.emailType != null) ? req.emailType.toUpperCase() : 'PD';
                String templateDevName = TEMPLATE_MAP.get(bType);
                if (templateDevName == null) {
                    throw new AuraHandledException('Unknown email type: ' + req.emailType);
                }

                // Generate-Only mints a fresh token; Send-Email reuses the stamped link if present.
                Opportunity oppRead = oppMap.get(req.opportunityId);
                String bookingLink = null;
                if (!skipEmail && oppRead != null) {
                    if (bType == 'PD' && String.isNotBlank(oppRead.PD_Scheduling_Link__c)) {
                        bookingLink = oppRead.PD_Scheduling_Link__c;
                    } else if (bType == 'FSS' && String.isNotBlank(oppRead.FSS_Scheduling_Link__c)) {
                        bookingLink = oppRead.FSS_Scheduling_Link__c;
                    }
                }
                if (String.isBlank(bookingLink)) {
                    String token = BookingTokenUtil.encrypt(req.contactId, req.opportunityId);
                    bookingLink = BOOKING_BASE_URL
                        + '?type=' + bType
                        + '&token=' + token;
                }

                if (!skipEmail) {
                    EmailTemplate tmpl = templateCache.get(templateDevName);
                    if (tmpl == null) {
                        throw new AuraHandledException(
                            'Email template "' + templateDevName + '" not found. '
                            + 'Please create it in Setup > Email Templates.');
                    }

                    // Lightning Email Template render: merge fields resolve natively from
                    // the Contact (whoId) and the specific Opportunity (whatId), so multi-Opp
                    // / shared-Primary-Contact families each receive the correct per-Opp link.
                    Messaging.SingleEmailMessage mail = Messaging.renderStoredEmailTemplate(
                        tmpl.Id, req.contactId, req.opportunityId
                    );
                    mail.setTargetObjectId(req.contactId);
                    mail.setWhatId(req.opportunityId);
                    mail.setSaveAsActivity(true);
                    mail.setUseSignature(false);

                    if (bType == 'FSS' && String.isNotBlank(FSS_CC_ADDRESS)) {
                        mail.setCcAddresses(new List<String>{ FSS_CC_ADDRESS });
                    }

                    emailsToSend.add(mail);
                    emailToResultIndex.add(i);
                }

                // Stamp link on Opportunity; advance Stage only on Send-Email path.
                Opportunity oppUpd = new Opportunity(Id = req.opportunityId);
                if (bType == 'PD') {
                    oppUpd.PD_Scheduling_Link__c = bookingLink;
                    if (!skipEmail && oppRead != null
                        && oppRead.StageName != 'SOM Scheduled'
                        && oppRead.StageName != 'Closed Won'
                        && oppRead.StageName != 'Closed Lost') {
                        oppUpd.StageName = 'SOM Link Sent';
                    }
                } else if (bType == 'FSS') {
                    oppUpd.FSS_Scheduling_Link__c = bookingLink;
                }
                oppsByRequestIndex.put(i, oppUpd);

                res.success = true;

            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }

        DateTime sendStartTime = DateTime.now();
        Map<Integer, Boolean> requestSucceeded = new Map<Integer, Boolean>();
        if (!emailsToSend.isEmpty()) {
            try {
                Messaging.SendEmailResult[] sendResults = Messaging.sendEmail(emailsToSend);
                for (Integer j = 0; j < sendResults.size(); j++) {
                    Integer resultIdx = emailToResultIndex[j];
                    if (sendResults[j].isSuccess()) {
                        requestSucceeded.put(resultIdx, true);
                    } else {
                        results[resultIdx].success = false;
                        String errMsg = '';
                        for (Messaging.SendEmailError err : sendResults[j].getErrors()) {
                            errMsg += err.getMessage() + ' ';
                        }
                        results[resultIdx].errorMessage = errMsg.trim();
                        oppsByRequestIndex.remove(resultIdx);
                    }
                }
            } catch (Exception ex) {
                for (Integer idx : emailToResultIndex) {
                    results[idx].success = false;
                    results[idx].errorMessage = 'Email send failed: ' + ex.getMessage();
                    oppsByRequestIndex.remove(idx);
                }
            }
        }

        // Re-stamp EmailMessage.RelatedToId to the Opportunity so emails land on the Opp activity timeline.
        Map<String, Id> emailAddrToOppId = new Map<String, Id>();
        for (Integer idx : requestSucceeded.keySet()) {
            EmailRequest req = requests[idx];
            Contact con = contactMap.get(req.contactId);
            if (con != null && String.isNotBlank(con.Email) && req.opportunityId != null) {
                emailAddrToOppId.put(con.Email.toLowerCase(), req.opportunityId);
            }
        }
        if (!emailAddrToOppId.isEmpty()) {
            try {
                Id currentUserId = UserInfo.getUserId();
                List<EmailMessage> recents = [
                    SELECT Id, ToAddress, RelatedToId
                    FROM EmailMessage
                    WHERE CreatedDate >= :sendStartTime
                    AND CreatedById = :currentUserId
                    LIMIT 200
                ];
                List<EmailMessage> emToUpdate = new List<EmailMessage>();
                for (EmailMessage em : recents) {
                    if (em.ToAddress == null) continue;
                    Id targetOpp = emailAddrToOppId.get(em.ToAddress.toLowerCase());
                    if (targetOpp != null && em.RelatedToId != targetOpp) {
                        em.RelatedToId = targetOpp;
                        emToUpdate.add(em);
                    }
                }
                if (!emToUpdate.isEmpty()) {
                    logSaveErrors('EmailMessage RelatedToId fix-up',
                        Database.update(emToUpdate, false));
                }
            } catch (Exception emEx) {
                System.debug(LoggingLevel.WARN,
                    'EmailMessage RelatedToId fix-up failed: ' + emEx.getMessage());
            }
        }

        // Deduplicate Opp updates by Id (last-write-wins) before bulk DML to avoid DUPLICATE_VALUE.
        if (!oppsByRequestIndex.isEmpty()) {
            Map<Id, Opportunity> mergedOpps = new Map<Id, Opportunity>();
            for (Opportunity src : oppsByRequestIndex.values()) {
                if (src == null || src.Id == null) continue;
                Opportunity dst = mergedOpps.get(src.Id);
                if (dst == null) {
                    mergedOpps.put(src.Id, src);
                    continue;
                }
                if (src.PD_Scheduling_Link__c  != null) dst.PD_Scheduling_Link__c  = src.PD_Scheduling_Link__c;
                if (src.FSS_Scheduling_Link__c != null) dst.FSS_Scheduling_Link__c = src.FSS_Scheduling_Link__c;
                if (src.StageName              != null) dst.StageName              = src.StageName;
            }
            try {
                logSaveErrors('Opportunity link update',
                    Database.update(mergedOpps.values(), false));
            } catch (Exception updEx) {
                System.debug(LoggingLevel.WARN,
                    'Opportunity link batch update failed: ' + updEx.getMessage());
            }
        }

        return results;
    }

    // Logs per-row partial DML failures to debug at WARN.
    private static void logSaveErrors(String label, Database.SaveResult[] saveResults) {
        if (saveResults == null) return;
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult sr = saveResults[i];
            if (sr.isSuccess()) continue;
            for (Database.Error err : sr.getErrors()) {
                System.debug(LoggingLevel.WARN,
                    label + ' partial failure [row ' + i + '] '
                    + err.getStatusCode() + ': ' + err.getMessage()
                    + ' fields=' + err.getFields());
            }
        }
    }

}
