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

        @InvocableVariable(label='Skip Email (generate link only)')
        public Boolean skipEmail;
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

        // ── 1. Bulk-collect IDs ──────────────────────────────────────────
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

        // ── 2. Pre-query ALL shared data OUTSIDE the loop ────────────────
        Map<Id, Contact> contactMap = new Map<Id, Contact>([
            SELECT Id, FirstName, LastName, Name, Email
            FROM Contact WHERE Id IN :contactIds
        ]);
        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>([
            SELECT Id, Name, Account.Name, StageName,
                   PD_Scheduling_Link__c, FSS_Scheduling_Link__c
            FROM Opportunity WHERE Id IN :oppIds
        ]);

        // Pre-query ALL email templates at once (no SOQL in loop)
        Map<String, EmailTemplate> templateCache = new Map<String, EmailTemplate>();
        for (EmailTemplate et : [
            SELECT Id, DeveloperName, Subject, HtmlValue, Body
            FROM EmailTemplate
            WHERE DeveloperName IN :templateDevNames
        ]) {
            templateCache.put(et.DeveloperName, et);
        }

        // ── 3. Build emails and collect DML ──────────────────────────────
        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
        // Track Opp updates keyed by request index so we can selectively
        // null out a request's link stamp if its email fails. Map (rather
        // than parallel List) keeps index bookkeeping correct even when
        // skipEmail=true on some requests but not others — those entries
        // get an Opp update without an emailsToSend entry.
        Map<Integer, Opportunity> oppsByRequestIndex = new Map<Integer, Opportunity>();
        // One activity Task per successful Send-Email request, keyed by
        // request index. Inserted only after Messaging.sendEmail confirms
        // success — keeps the Opportunity activity timeline in sync with
        // what was actually delivered. The Task carries both WhoId
        // (Contact) and WhatId (Opportunity) so it shows on both
        // timelines, regardless of whether the org has Enhanced Email
        // enabled. setSaveAsActivity is intentionally false below to
        // avoid the platform creating a duplicate auto-Task.
        Map<Integer, Task> activityTasksByRequestIndex = new Map<Integer, Task>();
        // Track which index maps to which request for result assembly
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

                // Determine the booking link:
                //   - skipEmail=true  (Generate-Only): always mint a fresh
                //     token. The button's purpose is to issue/refresh the
                //     link, so callers expect a new value each click.
                //   - skipEmail=false (Send-Email): reuse the link already
                //     stamped on the Opportunity if populated. Don't churn
                //     tokens just because someone wants to re-send the
                //     email — the same link must keep working. Only mint
                //     a fresh token when the field is blank, so the email
                //     always carries a working URL.
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

                    Contact con = contactMap.get(req.contactId);
                    Opportunity opp = oppMap.get(req.opportunityId);

                    // Start from the raw template HTML and subject
                    String htmlBody  = tmpl.HtmlValue;
                    String subject   = tmpl.Subject;
                    String plainBody = tmpl.Body;

                    // Replace merge fields
                    if (con != null) {
                        htmlBody  = replaceMerge(htmlBody, '{!Contact.FirstName}', con.FirstName);
                        htmlBody  = replaceMerge(htmlBody, '{!Contact.LastName}', con.LastName);
                        htmlBody  = replaceMerge(htmlBody, '{!Contact.Name}', con.Name);
                        subject   = replaceMerge(subject, '{!Contact.FirstName}', con.FirstName);
                        subject   = replaceMerge(subject, '{!Contact.LastName}', con.LastName);
                        subject   = replaceMerge(subject, '{!Contact.Name}', con.Name);
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

                    // Build email message. setSaveAsActivity is false here
                    // because we insert our own Task below — the manual
                    // Task carries WhatId, which the platform's auto-Task
                    // does not always populate reliably (Enhanced Email
                    // orgs sometimes route through EmailMessage instead,
                    // dropping the Opportunity link). Doing it manually
                    // guarantees the email shows on the Opportunity's
                    // activity timeline alongside the Contact's.
                    Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                    mail.setTargetObjectId(req.contactId);
                    mail.setWhatId(req.opportunityId);
                    mail.setSubject(subject);
                    mail.setHtmlBody(htmlBody);
                    if (plainBody != null) {
                        mail.setPlainTextBody(plainBody);
                    }
                    mail.setSaveAsActivity(false);
                    mail.setUseSignature(false);

                    if (bType == 'FSS') {
                        mail.setCcAddresses(new List<String>{ 'fss@zenithprepacademy.com' });
                    }

                    emailsToSend.add(mail);
                    emailToResultIndex.add(i);

                    // Build the activity Task for this request. WhoId on
                    // the Contact + WhatId on the Opportunity = a single
                    // Task that appears on both timelines.
                    Task t = new Task();
                    t.WhoId        = req.contactId;
                    t.WhatId       = req.opportunityId;
                    t.Subject      = 'Email: ' + subject;
                    t.Status       = 'Completed';
                    t.Priority     = 'Normal';
                    t.ActivityDate = Date.today();
                    tryPut(t, 'Type', 'Email');
                    t.Description  = (plainBody != null && plainBody.length() > 0)
                        ? plainBody
                        : htmlBody.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim();
                    activityTasksByRequestIndex.put(i, t);
                }

                // Pre-build Opportunity link + stage update.
                //   - PD link sent → stamp PD_Scheduling_Link__c (the
                //     populated value also serves as the "email already
                //     sent" guard via the flow's Check_PD_Link_Sent
                //     decision) and flip StageName to
                //     "SOM Scheduling Link Sent".
                //   - FSS link sent → stamp FSS_Scheduling_Link__c (same
                //     pattern: populated value is the duplicate-send guard
                //     via the flow's Check_FSS_Link_Sent decision).
                Opportunity oppUpd = new Opportunity(Id = req.opportunityId);
                if (bType == 'PD') {
                    oppUpd.PD_Scheduling_Link__c = bookingLink;
                    if (oppRead != null && oppRead.StageName != 'SOM Scheduled'
                        && oppRead.StageName != 'Closed Won'
                        && oppRead.StageName != 'Closed Lost') {
                        oppUpd.StageName = 'SOM Scheduling Link Sent';
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

        // ── 4. Batch send all emails at once ─────────────────────────────
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
                        // Drop this request's Opp link stamp so the next
                        // retry isn't blocked by the duplicate-send guard.
                        oppsByRequestIndex.remove(resultIdx);
                        // Don't log a "completed email" Task for a send
                        // that didn't actually go out.
                        activityTasksByRequestIndex.remove(resultIdx);
                    }
                }
            } catch (Exception ex) {
                // If batch send fails entirely, mark all email results as failed
                for (Integer idx : emailToResultIndex) {
                    results[idx].success = false;
                    results[idx].errorMessage = 'Email send failed: ' + ex.getMessage();
                    oppsByRequestIndex.remove(idx);
                    activityTasksByRequestIndex.remove(idx);
                }
            }
        }

        // ── 4b. Insert activity Tasks for delivered emails ───────────────
        // Best-effort: a Task insert failure must not bubble up and roll
        // back the email + Opp link stamp. The email already went out;
        // missing a timeline entry is recoverable, a thrown exception
        // back to the flow is not.
        if (!activityTasksByRequestIndex.isEmpty()) {
            try { insert activityTasksByRequestIndex.values(); }
            catch (Exception tEx) {
                System.debug(LoggingLevel.WARN,
                    'Email activity Task batch insert failed: ' + tEx.getMessage());
            }
        }

        // ── 5. Batch update Opportunity links ────────────────────────────
        if (!oppsByRequestIndex.isEmpty()) {
            try {
                update oppsByRequestIndex.values();
            } catch (Exception updEx) {
                System.debug(LoggingLevel.WARN,
                    'Opportunity link batch update failed: ' + updEx.getMessage());
            }
        }

        return results;
    }

    private static String replaceMerge(String source, String mergeField, String value) {
        if (source == null) return source;
        return source.replace(mergeField, (value != null) ? value : '');
    }

    private static void tryPut(SObject rec, String fieldName, Object val) {
        try { rec.put(fieldName, val); } catch (Exception ex) { }
    }
}
