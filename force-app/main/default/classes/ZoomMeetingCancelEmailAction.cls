// Flow-callable Invocable that sends a cancellation email with a METHOD:CANCEL .ics so calendar clients purge the event.
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