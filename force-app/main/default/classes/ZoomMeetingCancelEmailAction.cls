// Flow-callable Invocable that sends a cancellation email with a METHOD:CANCEL .ics so calendar clients purge the event.
public class ZoomMeetingCancelEmailAction {

    public class Input {
        @InvocableVariable(
            required=true
            label='Service Appointment Id'
            description='SA whose cancellation email + .ics should be sent.')
        public Id serviceAppointmentId;

        @InvocableVariable(
            required=false
            label='Email Template Id'
            description='Lightning Email Template Id. Provide this OR emailTemplateDeveloperName.')
        public Id emailTemplateId;

        @InvocableVariable(
            required=false
            label='Email Template Developer Name'
            description='Lightning Email Template DeveloperName. Resolved to Id at runtime; portable across sandbox + prod (Ids differ between orgs). Used only when emailTemplateId is blank.')
        public String emailTemplateDeveloperName;
    }

    @InvocableMethod(
        label='Send Zenith Meeting Cancellation Email With ICS'
        description='Sends the chosen Lightning cancellation template plus a METHOD:CANCEL .ics so the event is removed from every recipient\'s calendar.'
        callout=false)
    public static void send(List<Input> inputs) {
        if (inputs == null || inputs.isEmpty()) return;

        // Bulk-collect any DeveloperNames that need resolution to Ids.
        Set<String> devNames = new Set<String>();
        for (Input i : inputs) {
            if (i == null) continue;
            if (i.emailTemplateId == null && String.isNotBlank(i.emailTemplateDeveloperName)) {
                devNames.add(i.emailTemplateDeveloperName);
            }
        }

        // Single SOQL resolves every DeveloperName at once.
        Map<String, Id> idByDevName = new Map<String, Id>();
        if (!devNames.isEmpty()) {
            for (EmailTemplate et : [
                SELECT Id, DeveloperName FROM EmailTemplate
                WHERE DeveloperName IN :devNames
            ]) {
                idByDevName.put(et.DeveloperName, et.Id);
            }
        }

        Map<Id, Id> templateBySa = new Map<Id, Id>();
        for (Input i : inputs) {
            if (i == null) continue;
            if (i.serviceAppointmentId == null) continue;
            Id resolvedId = i.emailTemplateId;
            if (resolvedId == null && String.isNotBlank(i.emailTemplateDeveloperName)) {
                resolvedId = idByDevName.get(i.emailTemplateDeveloperName);
            }
            if (resolvedId == null) continue;
            templateBySa.put(i.serviceAppointmentId, resolvedId);
        }
        if (!templateBySa.isEmpty()) {
            ZoomMeetingManager.sendCancellationsForSavedAppointments(templateBySa);
        }
    }
}
