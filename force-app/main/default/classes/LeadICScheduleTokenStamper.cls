/**
 * Generates a fresh, single-use IC schedule token + the full booking URL
 * for one or more Lead Ids.
 *
 * Called from the record-triggered flow Lead_Generate_IC_Schedule_Token,
 * which fires on Lead create when:
 *   - IC_Schedule_Token__c is blank, AND
 *   - Service_Appointment__c is blank, AND
 *   - IsConverted = false.
 *
 * The flow assigns the returned token + link onto the same Lead record so
 * an AC / marketing user can copy IC_Schedule_Link__c and share an
 * initial-call booking URL with the family.
 *
 * Token generation reuses RescheduleTokenService.generateToken() (256-bit
 * random, hex-encoded, 64 chars) so the same uniqueness guarantees apply
 * as the existing IC reschedule + SA reschedule tokens.
 */
public without sharing class LeadICScheduleTokenStamper {

    private static final String BOOKING_BASE_URL =
        'https://site-enterprise-6958--dev2.sandbox.my.site.com/booking';

    public class Request {
        @InvocableVariable(label='Lead Id') public Id leadId;
    }

    public class Result {
        @InvocableVariable public String token;
        @InvocableVariable public String link;
    }

    @InvocableMethod(
        label='Generate IC Schedule Token'
        description='Returns a fresh 64-char IC schedule token + full booking URL per request. Called from the Lead_Generate_IC_Schedule_Token flow.'
        category='Scheduling'
    )
    public static List<Result> generate(List<Request> requests) {
        List<Result> out = new List<Result>();
        if (requests == null || requests.isEmpty()) return out;

        // Bulk-fetch the Leads so we can apply the same site-booked guard
        // the Lead_Generate_IC_Schedule_Token flow uses, but at the Apex
        // layer too. Defense-in-depth: future callers, anonymous Apex,
        // direct REST invocations, or a flow that's missing the start
        // filter all hit this guard, so a Lead created by the booking
        // site never accidentally gets a fresh "schedule again" link.
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

            // Skip generation when the Lead is already booked through the
            // site portal. Returning a Result with null token/link is the
            // signal to the calling flow's Stamp step that nothing should
            // be written — and because the auto-flow's start filter
            // already excludes Leads with a populated token, this null
            // write only ever lands on Leads whose token was already null
            // (no data loss).
            //   - Status='IC Scheduled'      → site booking happened
            //   - Meeting_Status__c='Scheduled' → site booking happened
            //   - Service_Appointment__c set → SA already linked
            //   - IC_Schedule_Token__c set   → don't churn the existing token
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
