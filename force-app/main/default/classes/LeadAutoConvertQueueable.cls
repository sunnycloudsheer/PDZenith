// Async wrapper for LeadAutoConvert.convertLeads — runs after the triggering Lead update commits.
public with sharing class LeadAutoConvertQueueable implements Queueable {
    private final Set<Id> leadIds;

    public LeadAutoConvertQueueable(Set<Id> leadIds) {
        this.leadIds = leadIds;
    }

    public void execute(QueueableContext context) {
        LeadAutoConvert.convertLeads(this.leadIds);
    }
}
