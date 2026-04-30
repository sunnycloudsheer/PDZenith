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
        for (Integer i = 0; i < requests.size(); i++) {
            Result r = new Result();
            r.token = RescheduleTokenService.generateToken();
            r.link  = BOOKING_BASE_URL
                + '?type=IC&action=schedule&token=' + r.token;
            out.add(r);
        }
        return out;
    }
}
