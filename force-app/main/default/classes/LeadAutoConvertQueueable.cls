/**
 * Async wrapper around LeadAutoConvert.convertLeads. The trigger enqueues this
 * so the actual conversion runs after the current Lead update transaction
 * commits — this avoids mixed-DML errors and re-entrancy when the conversion
 * itself updates the Lead row (IsConverted = true).
 */
public with sharing class LeadAutoConvertQueueable implements Queueable {
    private final Set<Id> leadIds;

    public LeadAutoConvertQueueable(Set<Id> leadIds) {
        this.leadIds = leadIds;
    }

    public void execute(QueueableContext context) {
        LeadAutoConvert.convertLeads(this.leadIds);
    }
}
