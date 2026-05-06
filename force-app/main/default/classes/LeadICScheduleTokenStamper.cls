// Generates a fresh IC schedule token + booking URL for a Lead; called from Lead_Generate_IC_Schedule_Token flow.
public without sharing class LeadICScheduleTokenStamper {

    // Resolves dynamically per environment from the org's My Domain URL: sandbox/prod-safe.
    private static final String BOOKING_BASE_URL =
        URL.getOrgDomainUrl().toExternalForm().replace('.my.salesforce.com', '.my.site.com') + '/booking';

    public class Request {
        @InvocableVariable(label='Lead Id') public Id leadId;
    }

    public class Result {
        @InvocableVariable public String token;
        @InvocableVariable public String link;
    }

    // Returns a fresh 64-char IC schedule token + booking URL per request, skipping site-booked Leads.
    @InvocableMethod(
        label='Generate IC Schedule Token'
        description='Returns a fresh 64-char IC schedule token + full booking URL per request. Called from the Lead_Generate_IC_Schedule_Token flow.'
        category='Scheduling'
    )
    public static List<Result> generate(List<Request> requests) {
        List<Result> out = new List<Result>();
        if (requests == null || requests.isEmpty()) return out;

        Set<Id> leadIds = new Set<Id>();
        for (Request req : requests) {
            if (req != null && req.leadId != null) leadIds.add(req.leadId);
        }
        Map<Id, Lead> leadMap = new Map<Id, Lead>();
        if (!leadIds.isEmpty()) {
            for (Lead ld : [
                SELECT Id, Status, Meeting_Status__c,
                       Service_Appointment__c, IC_Schedule_Token__c
                FROM Lead WHERE Id IN :leadIds
            ]) {
                leadMap.put(ld.Id, ld);
            }
        }

        for (Integer i = 0; i < requests.size(); i++) {
            Result r = new Result();
            Request req = requests[i];
            Lead ld = (req != null && req.leadId != null)
                ? leadMap.get(req.leadId) : null;

            // Skip Leads already booked via the site so existing tokens are not churned.
            Boolean isSiteBooked = ld != null && (
                'IC Scheduled'.equals(ld.Status)
                || 'Scheduled'.equals(ld.Meeting_Status__c)
                || ld.Service_Appointment__c != null
                || String.isNotBlank(ld.IC_Schedule_Token__c)
            );
            if (isSiteBooked) {
                out.add(r);
                continue;
            }

            r.token = RescheduleTokenService.generateToken();
            r.link  = BOOKING_BASE_URL
                + '?type=IC&action=schedule&token=' + r.token;
            out.add(r);
        }
        return out;
    }
}
