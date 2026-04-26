/**
 * @File Name          : ZoomMeetingCancelEmailAction.cls
 * @Description        : Flow-callable Invocable that sends a meeting
 *                       cancellation email. The Lightning template is
 *                       chosen by the caller (Meeting_After_RTF's
 *                       Check_Meeting_Status decision routes ES/AC cancel
 *                       to one template and student/parent cancel to
 *                       another), and a METHOD:CANCEL .ics is attached so
 *                       calendar clients purge the event.
 *
 *                       Apex is required here because flow's emailSimple
 *                       action can't attach files — without this Invocable,
 *                       cancellations would leave orphaned events on
 *                       student / parent / ES calendars.
 *
 * @Author             : Amit Yadav
 * @Created On         : April 2026
 */
public class ZoomMeetingCancelEmailAction {

    public class Input {
        @InvocableVariable(
            required=true
            label='Service Appointment Id'
            description='SA whose cancellation email + .ics should be sent.')
        public Id serviceAppointmentId;

        @InvocableVariable(
            required=true
            label='Email Template Id'
            description='Lightning Email Template to use for the body / subject. The flow picks ES-cancel vs client-cancel.')
        public Id emailTemplateId;
    }

    @InvocableMethod(
        label='Send Zenith Meeting Cancellation Email With ICS'
        description='Sends the chosen Lightning cancellation template plus a METHOD:CANCEL .ics so the event is removed from every recipient\'s calendar.'
        callout=false)
    public static void send(List<Input> inputs) {
        if (inputs == null || inputs.isEmpty()) return;
        Map<Id, Id> templateBySa = new Map<Id, Id>();
        for (Input i : inputs) {
            if (i == null) continue;
            if (i.serviceAppointmentId == null || i.emailTemplateId == null) continue;
            templateBySa.put(i.serviceAppointmentId, i.emailTemplateId);
        }
        if (!templateBySa.isEmpty()) {
            ZoomMeetingManager.sendCancellationsForSavedAppointments(templateBySa);
        }
    }
}