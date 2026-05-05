# PDZenith — v14 Production Deployment Document

## Document Control

| Field | Value |
|---|---|
| Document title | PDZenith v14 Deployment Plan |
| Release | v14 |
| Source branch | `v14` |
| Source repository | `sunnycloudsheer/PDZenith` |
| Salesforce API version | 66.0 |
| Project type | Salesforce DX (`force-app/`) |
| Prepared for | Zenith Prep Academy |
| Prepared by | Cloudsheer Consulting |
| Status | Draft for client review |

### Revision History

| Version | Date | Author | Notes |
|---|---|---|---|
| 0.1 | 2026-05-05 | Cloudsheer | Initial draft — components inventoried, prerequisites mapped, URL hard-codes identified |

### Glossary

| Term | Meaning |
|---|---|
| Apex | Salesforce server-side code |
| LWC | Lightning Web Component (UI component) |
| Flow | Salesforce declarative automation |
| SA | Service Appointment (Salesforce Field Service object) |
| FSL | Field Service Lightning |
| WT / WTG | Work Type / Work Type Group (FSL configuration) |
| PD | Program Director |
| FSS | Family Success Specialist |
| IC | Initial Consultation |
| SOM | Strategy Overview Meeting |
| SF CLI | The `sf` command line tool (`@salesforce/cli`) |
| Org-wide test coverage | Aggregate Apex test coverage; production deploys require ≥ 75 % |

---

## 1. Executive Summary

Release **v14** delivers four functional areas:

1. **Lead family-data capture** — two new Lightning components (`leadStudentManager`, `leadParentGuardianManager`) replace ad-hoc field entry on the Lead page with a structured roster of up to 3 students and 2 adults (Primary parent and a Second adult — Parent or Guardian). Each row is stamped with a stable identifier (`P-XXXXXXXX` / `S-XXXXXXXX`) that survives Lead conversion.
2. **Lead-to-Opportunity automation** — a Queueable + Invocable Apex pipeline (`LeadAutoConvert`, `LeadAutoConvertQueueable`) plus three new flows (`Lead_Auto_Convert`, `Lead_Manual_Convert_Extras`, `Lead_Company_AutoFill_Before_Save`) automate conversion when a Lead reaches `IC Completed – Qualified` status, creating Family Account, Parent Contact(s), Student Contact(s), and Opportunity in one transaction.
3. **Opportunity pipeline manager** — `opportunityPipeline` LWC + `OpportunityPipelineController` Apex give users an in-place control to advance an Opportunity through its Stage and Pipeline Group, with optional chained advance.
4. **Booking & meeting refinements** — significant updates to `PD_Book_SOM_Call`, a new `Cancellation_of_Scheduled_Meeting` flow, an `Opportunity_Name_From_Student_OCR` flow, plus expanded Apex test coverage.

There are **no destructive changes** introduced by v14. All metadata changes are additive or modify existing components; no fields, classes, or flows are removed.

**Estimated deployment window:** 60–90 minutes for a sandbox dry-run, 30–45 minutes for the production deploy itself, plus 30–45 minutes of post-deploy validation.

---

## 2. Component Inventory

### 2.1 Apex Classes — 28 total

#### Production classes (19)

| Class | New / Modified / Existing | Purpose |
|---|---|---|
| `BookingTokenUtil` | Existing | Generates and parses opaque booking tokens |
| `FSSRoundRobinController` | Existing | Round-robin selection of Family Success Specialists |
| `GuestSchedulerController` | **Modified** | Apex backend for the public `/booking` site; opportunity-scoped existing-meeting checks added |
| `LeadAutoConvert` | **New** | Core Lead-conversion logic; exposes `@InvocableMethod convertLeadsInvocable` |
| `LeadAutoConvertQueueable` | **New** | Async wrapper so flows can fire the convert without Limits violations |
| `LeadFamilyController` | **New** | `@AuraEnabled` controller for the Student and Parent/Guardian managers |
| `LeadICEmailSender` | Existing | Sends IC scheduling emails |
| `LeadICScheduleTokenStamper` | **Modified** | Stamps `Lead.IC_Schedule_Token__c` and link; auto-suppression for site-booked leads |
| `OpportunityPipelineController` | **New** | `@AuraEnabled updateOpportunityStage(...)` — single-call StageName + Pipeline_Group__c update with optional chained advance |
| `PDPostBookingHandler` | **Modified** | Post-booking PD assignment + opportunity field stamping |
| `PDRoundRobinHandler` | Existing | Round-robin selection of Program Directors |
| `PDSchedulingConfigHandler` | Existing | Resolves Service Territory / Work Type / Work Type Group by role |
| `RescheduleTokenService` | Existing | Generates reschedule URLs |
| `SchedulingEmailSender` | **Modified** | Generates and/or emails scheduling links — PD/FSS/IC; `skipEmail` mode added |
| `ZoomIcsBuilder` | Existing | Builds `.ics` calendar attachment |
| `ZoomMeetingCancelEmailAction` | Existing | Cancellation email action |
| `ZoomMeetingEmailService` | **Modified** | Reminder/confirmation emails |
| `ZoomMeetingManager` | Existing | Zoom callout orchestration (Named Credential `Zoom_App`) |
| `ZoomMeetingService` | Existing | Lower-level Zoom REST helpers |

#### Test classes (9 — all run during deployment)

| Class | New / Existing | Targets |
|---|---|---|
| `GuestSchedulerControllerTest` | **New** | `GuestSchedulerController` |
| `LeadAutoConvertTest` | **New** | `LeadAutoConvert` (sync paths) |
| `LeadAutoConvertQueueableTest` | **New** | `LeadAutoConvertQueueable` (async path) |
| `LeadFamilyControllerTest` | **New** | `LeadFamilyController` |
| `LeadICEmailSenderTest` | **New** | `LeadICEmailSender` |
| `LeadICScheduleTokenStamperTest` | **New** | `LeadICScheduleTokenStamper` |
| `PDSchedulerHandlersTest` | Existing | `PDPostBookingHandler`, `PDRoundRobinHandler`, `PDSchedulingConfigHandler` |
| `SchedulingEmailSenderTest` | **New** | `SchedulingEmailSender` |
| `ZoomMeetingManagerTest` | **New** | `ZoomMeetingManager` (HTTP mocked) |

### 2.2 Flows — 14 total

#### New flows (5)

| Flow | Type | Trigger | Object | Notes |
|---|---|---|---|---|
| `Lead_Auto_Convert` | Auto-launched, Record-After-Save | Update | Lead | Calls `LeadAutoConvert` invocable when `Status` reaches `IC Completed – Qualified` |
| `Lead_Manual_Convert_Extras` | Auto-launched, Record-After-Save | Update | Lead | Runs `createExtrasForConvertedLeads` when `IsConverted` flips true via the standard Convert button |
| `Lead_Company_AutoFill_Before_Save` | Auto-launched, Record-Before-Save | Create + Update | Lead | Sets `Company` from `LastName` when `Company` is blank |
| `Cancellation_of_Scheduled_Meeting` | Screen | n/a (manual) | ServiceAppointment | Cancels SA, sends cancellation email, stamps `Cancellation_Reason__c` and `Date_Time_Cancelled__c` |
| `Opportunity_Name_From_Student_OCR` | Auto-launched, Record-After-Save | Create + Update | Opportunity | Sets `Opportunity.Name` to "<Student Full Name> – <Family Name>" derived from the Student-record-type Contact in `OpportunityContactRole` |

#### Modified flows (4)

| Flow | Change |
|---|---|
| `PD_Book_SOM_Call` | Generate-Link buttons (PD + FSS), reuses populated link, FSS Follow-Up booking via assigned FSS, opp-scoped existing-meeting checks, in-place reschedule polish (~1,400 lines of XML diff) |
| `Create_Meeting_Zoom_Link_And_Send_Reminders` | Reminder routing updates |
| `Lead_Generate_IC_Schedule_Token` | Suppress generation for leads booked via the public site |
| `Zoom_Meeting_Update_Or_Cancel` | Update/cancel routing refinements |

#### Unchanged flows (5) — included for completeness
`FSS_Auto_Assignment_On_Contract_Signed`, `Lead_Send_IC_Schedule_Link`, `Meeting_After_RTF`, `Opportunity_Stage_To_Student_Contact_Sync`, `SA_Mark_Rescheduled_On_Time_Change`

### 2.3 Lightning Web Components — 6 total

| LWC | Status | Targets | Backed by |
|---|---|---|---|
| `leadStudentManager` | **New, exposed** | `lightning__RecordPage` (Lead), `lightning__RecordAction` | `LeadFamilyController.getStudents/saveStudents/deleteStudent` |
| `leadParentGuardianManager` | **New, exposed** | `lightning__RecordPage` (Lead), `lightning__RecordAction` | `LeadFamilyController.getAdults/saveAdults` |
| `opportunityPipeline` | **New, exposed** | `lightning__RecordPage` (Opportunity) | `OpportunityPipelineController.updateOpportunityStage` |
| `guestbookingscheduler` | **Modified** | Experience Cloud `/booking` site | `GuestSchedulerController` |
| `guestRescheduleCancel` | Existing (un-exposed child) | Used inside `guestbookingscheduler` | `GuestSchedulerController` |

### 2.4 Custom Fields — 8 new

#### Lead

| API name | Label | Type | Length / Picklist values | Description |
|---|---|---|---|---|
| `Parent_1_ID__c` | Parent 1 ID | Text | 32 | Stable ID for Primary parent (`P-XXXXXXXX`); auto-stamped by `leadParentGuardianManager`; mapped to `Contact.Parent_ID__c` at convert |
| `Parent_2_ID__c` | Parent 2 ID | Text | 32 | Stable ID for Second adult; mapped to `Contact.Parent_ID__c` at convert |
| `Second_Adult_Type__c` | Second Adult Type | Picklist (restricted) | `Parent`, `Guardian` | Distinguishes Parent vs. Guardian on the second adult |
| `Student_ID_1__c` | Student 1 ID | Text | 32 | Stable ID for Student 1 (`S-XXXXXXXX`); mapped to `Contact.Student_ID__c` at convert |
| `Student_ID_2__c` | Student 2 ID | Text | 32 | Stable ID for Student 2 |
| `Student_ID_3__c` | Student 3 ID | Text | 32 | Stable ID for Student 3 |

#### Contact

| API name | Label | Type | Length | Description |
|---|---|---|---|---|
| `Parent_ID__c` | Parent ID | Text | 32 | Mirror of `Lead.Parent_1_ID__c` / `Lead.Parent_2_ID__c`; populated only on Parent record-type Contacts |
| `Student_ID__c` | Student ID | Text | 32 | Mirror of `Lead.Student_ID_1__c` / `_2__c` / `_3__c`; populated only on Student record-type Contacts |

> **Note on Contact:** v14 is the first release that ships Contact custom-field metadata in this repo. The folder `force-app/main/default/objects/Contact/` is created on this branch.

### 2.5 Other Metadata

| Type | Component | Status |
|---|---|---|
| Quick Action | `Lead.Send_IC_Schedule_Link` (Flow QA) | Existing |
| Quick Action | `Opportunity.Book_Meeting` (Flow QA) | Existing |
| Email Template | `Scheduling_Templates/PD_Scheduling_Email` | Existing |
| Email Template | `Scheduling_Templates/FSS_Scheduling_Email` | Existing |
| Email Template | `Scheduling_Templates/IC_Scheduling_Email` | Existing |
| Letterhead | `Zenith_Prep_Classic_Letterhead` | Existing |

---

## 3. Pre-Deployment Prerequisites

### 3.1 Configuration that must already exist in the target org

| # | Item | Used by | How to verify | Action if missing |
|---|---|---|---|---|
| 1 | **Named Credential `Zoom_App`** with Zoom Server-to-Server OAuth credentials | `ZoomMeetingManager`, `ZoomMeetingService` | Setup → Named Credentials → confirm `Zoom_App` exists and authenticates | Create Named Credential and External Credential per Zoom S2S OAuth setup; supply Client ID, Client Secret, Account ID |
| 2 | **Custom Metadata Type `Slack_Config__mdt`** with at least one record where `Active__c = true` and `Is_Default__c = true` | Slack notification helpers | Setup → Custom Metadata Types → `Slack Config` → "Manage Records" → confirm at least one Active + Default record exists | Create the type (already in `manifest/package.xml`) and seed a record with `Webhook_URL__c` and `Channel_Name__c` |
| 3 | **Experience Site published at path `/booking`** | Public scheduling | Setup → Digital Experiences → All Sites → confirm the site is **Live** and the booking page renders | Activate site and publish the page |
| 4 | **Field Service** Service Resources, Service Territory Members, Work Types, Work Type Groups, Operating Hours for **PD** and **FSS** users | Booking flows | Run the SOQL in §3.3 | Configure missing rows |
| 5 | **Profile "Program Director"** (or equivalent) on PD users | `PDPostBookingHandler`, error screens | Setup → Profiles → confirm | Create / clone if absent |
| 6 | **Lead Conversion field mapping** (Lead → Account/Contact/Opportunity) including the new ID fields if you want them mapped automatically by the Convert button | Standard Lead conversion (`Lead_Manual_Convert_Extras` is a safety net but the standard map is preferred) | Setup → Lead Settings → "Map Lead Fields" | Add mappings before activating `Lead_Manual_Convert_Extras` |
| 7 | **Account Record Type "Family"**, **Contact Record Types "Parent" and "Student"** | `LeadAutoConvert` | Setup → Object Manager → Account / Contact → Record Types | Create if absent — `LeadAutoConvert` will throw if either Contact RT is missing |
| 8 | **Opportunity stage** `Ready to Schedule SOM` and **Pipeline Group** picklist values used in the Opportunity Pipeline LWC | `LeadAutoConvert`, `OpportunityPipelineController` | Setup → Object Manager → Opportunity → Stage / Picklist Values | Add stage / values |
| 9 | **Lead status values** `IC Completed – Qualified` (trigger) and `Converted (SOM Scheduled)` (post-convert) | `LeadAutoConvert`, `Lead_Auto_Convert` flow | Setup → Object Manager → Lead → Lead Status | Add values |

### 3.2 Org-existing custom fields referenced by v14

These fields are referenced by Apex/flows in this release but are **not** part of this release; they were created in earlier work and live in the production org. They are listed in `manifest/package.xml`. Verify each exists before deploy.

```
Account.Assigned_FSS__c
Contact.Portal_Active__c
Contact.Stage__c
Lead.Assigned_PD__c
Lead.IC_No_Show_Count__c
Lead.IC_Schedule_Link__c
Lead.IC_Schedule_Token__c
Lead.IC_Reschedule_Link__c
Lead.IC_Reschedule_Token__c
Lead.No_of_Student_Enrolling_Today__c
Lead.Status (custom values per §3.1 #9)
Opportunity.Assigned_FSS__c
Opportunity.Billing_Setup_Complete__c
Opportunity.Family_Success_Specialist__c
Opportunity.First_Payment_Received__c
Opportunity.Landing_Page_Source__c
Opportunity.LeadId__c
Opportunity.Pipeline_Group__c
Opportunity.Program_Director__c
ServiceAppointment.Appointment_Status_Custom__c
ServiceAppointment.Cancel_URL__c
ServiceAppointment.Cancellation_Reason__c
ServiceAppointment.Date_Time_Cancelled__c
ServiceAppointment.Is_Duplicate_Family__c
ServiceAppointment.Meeting_Type__c
ServiceAppointment.Opportunity__c
ServiceAppointment.Reschedule_Token__c
ServiceAppointment.Reschedule_URL__c
ServiceResource.Appointment_Count__c
ServiceResource.Role__c
ServiceResource.Weight__c
User.Followup_Booking_URL__c
User.Personal_Booking_URL__c
User.RR_Booking_URL__c
```

### 3.3 Pre-flight verification queries

Run these **before** deploying. Each must return a non-zero count (or the expected boolean state).

```sql
-- (A) Named Credential present
SELECT Id, DeveloperName FROM NamedCredential WHERE DeveloperName = 'Zoom_App'

-- (B) Slack_Config__mdt active default
SELECT Id, DeveloperName, Active__c, Is_Default__c
FROM Slack_Config__mdt WHERE Active__c = true AND Is_Default__c = true

-- (C) Family Account RT and Parent/Student Contact RTs
SELECT Id, DeveloperName, SobjectType FROM RecordType
WHERE (SobjectType = 'Account' AND DeveloperName = 'Family')
   OR (SobjectType = 'Contact' AND DeveloperName IN ('Parent','Student'))

-- (D) Lead status values present
SELECT MasterLabel, IsConverted FROM LeadStatus
WHERE MasterLabel IN ('IC Completed – Qualified','Converted (SOM Scheduled)')

-- (E) PD Field Service config (any active PD resource with a territory + WTG)
SELECT sr.Id, sr.Name, stm.ServiceTerritoryId, wtgm.WorkTypeGroupId
FROM ServiceResource sr
LEFT JOIN ServiceTerritoryMember stm ON stm.ServiceResourceId = sr.Id
LEFT JOIN WorkTypeGroupMember wtgm  ON wtgm.WorkTypeId = stm.OperatingHours.Id  -- example join
WHERE sr.IsActive = true AND sr.Role__c = 'PD'
```

> The exact "Is the Field Service config complete?" query depends on data shape; in practice the booking flows are the strongest test — see §7.4.

---

## 4. Critical Pre-Deploy Action — Replace Sandbox URLs

### 4.1 What to replace

The **sandbox booking site URL** is hard-coded in 6 places. This **must be changed** before deploying to Production.

| File | Line | Current value |
|---|---|---|
| [`force-app/main/default/classes/LeadICScheduleTokenStamper.cls`](force-app/main/default/classes/LeadICScheduleTokenStamper.cls#L22) | 22 | `https://site-enterprise-6958--dev2.sandbox.my.site.com/booking` |
| [`force-app/main/default/classes/RescheduleTokenService.cls`](force-app/main/default/classes/RescheduleTokenService.cls#L4) | 4 | same |
| [`force-app/main/default/classes/GuestSchedulerController.cls`](force-app/main/default/classes/GuestSchedulerController.cls#L1722) | 1722 | same |
| [`force-app/main/default/classes/SchedulingEmailSender.cls`](force-app/main/default/classes/SchedulingEmailSender.cls#L18) | 18 | same |
| [`force-app/main/default/flows/PD_Book_SOM_Call.flow-meta.xml`](force-app/main/default/flows/PD_Book_SOM_Call.flow-meta.xml) | `fssEmailBody` and `pdEmailBody` formula nodes | same |
| [`force-app/main/default/flows/Create_Meeting_Zoom_Link_And_Send_Reminders.flow-meta.xml`](force-app/main/default/flows/Create_Meeting_Zoom_Link_And_Send_Reminders.flow-meta.xml#L833) | 833 | `https://site-enterprise-6958.lightning.force.com/...` (Lightning record link) |

### 4.2 Recommended replacement procedure

1. From the client, obtain the **Production booking site URL**, e.g. `https://www.zenithprepacademy.com/booking` (or the canonical `*.my.site.com` if no custom domain).
2. From the client, obtain the **Production Lightning base URL**, e.g. `https://zenithprep.lightning.force.com`.
3. Create a release branch off `v14`:

   ```bash
   git checkout v14
   git pull
   git checkout -b release/v14-prod
   ```

4. Run a controlled find-and-replace (review each diff before committing):

   ```bash
   # Booking URL
   grep -rl "site-enterprise-6958--dev2.sandbox.my.site.com/booking" force-app/ \
     | xargs sed -i '' 's#https://site-enterprise-6958--dev2.sandbox.my.site.com/booking#https://<PROD_BOOKING_HOST>/booking#g'

   # Lightning base URL
   grep -rl "site-enterprise-6958.lightning.force.com" force-app/ \
     | xargs sed -i '' 's#https://site-enterprise-6958.lightning.force.com#https://<PROD_LIGHTNING_HOST>#g'
   ```

5. **Diff review** — verify changes are limited to the 6 files in §4.1:

   ```bash
   git diff --stat
   git diff
   ```

6. Commit:

   ```bash
   git add force-app/
   git commit -m "v14: replace sandbox booking + Lightning URLs with production URLs"
   ```

7. Deploy from this `release/v14-prod` branch.

### 4.3 Recommended follow-up (non-blocking)

In a subsequent release (`v15`), refactor the booking URL into a **Custom Label** (e.g. `Booking_Site_Base_URL`) so future environment changes are configuration-only. The 4 Apex classes can read it via `System.Label.Booking_Site_Base_URL`; flow formulas can reference `$Label.Booking_Site_Base_URL`.

---

## 5. Deployment Order

A single source-deploy resolves dependencies automatically. The conceptual order, if deploying in stages, is:

1. **Custom fields** (Lead + Contact — §2.4)
2. **Custom Metadata** (`Slack_Config__mdt` if not yet in org)
3. **Named Credential** `Zoom_App` (manual in Setup; not in repo)
4. **Apex classes + tests** (with `RunLocalTests` for prod, `RunSpecifiedTests` for sandbox)
5. **Flows** — latest version becomes Active; older versions are retained
6. **LWCs**
7. **Quick Actions** (depend on flows being active)
8. **Email Templates and Letterhead** (no consumers added in v14, but already in repo)
9. **Lightning Record Pages / Page Layouts** — manual (Lightning App Builder), see §7.2

---

## 6. Deployment Procedure

### 6.1 Authenticate to the target org

```bash
# Production (one-time per machine)
sf org login web --alias ZenithProd --instance-url https://login.salesforce.com

# Or, sandbox
sf org login web --alias ZenithUAT --instance-url https://test.salesforce.com

# Confirm
sf org list
sf org display --target-org ZenithProd
```

### 6.2 Stage 1 — Sandbox / UAT dry run (mandatory)

```bash
# From release/v14-prod branch (URL replacements applied)
git checkout release/v14-prod

sf project deploy start \
  --source-dir force-app \
  --test-level RunLocalTests \
  --target-org ZenithUAT \
  --wait 60 \
  --verbose
```

**Acceptance criteria for Stage 1:**

- Deploy completes without errors.
- Org-wide Apex code coverage is ≥ 75 %.
- All 9 v14 test classes pass (0 failures).
- Smoke tests in §7.4 pass in sandbox.

### 6.3 Stage 2 — Production validate-only

```bash
sf project deploy validate \
  --source-dir force-app \
  --test-level RunLocalTests \
  --target-org ZenithProd \
  --wait 60 \
  --verbose
```

The output prints a **Deployment ID** (e.g. `0Af...`) — record it.

**Acceptance criteria for Stage 2:**

- Validation succeeds with 0 errors.
- All managed-package and pre-existing tests pass.
- Org-wide coverage ≥ 75 %.
- Component count matches expectations (≈ 60 components).

### 6.4 Stage 3 — Production quick deploy

Within **10 days** of a successful validation, deploy without re-running tests:

```bash
sf project deploy quick \
  --job-id 0AfXXXXXXXXXXXXXXX \
  --target-org ZenithProd
```

**Acceptance criteria for Stage 3:**

- Deploy status = `Succeeded`.
- Setup → Deployment Status confirms green check on all components.

### 6.5 Stage 4 — Post-deploy configuration

Execute every item in §7.

### 6.6 Sandbox-only fast option

For a quick refresh in lower environments (skips full org tests):

```bash
sf project deploy start \
  --source-dir force-app \
  --test-level RunSpecifiedTests \
  --tests GuestSchedulerControllerTest LeadAutoConvertTest LeadAutoConvertQueueableTest \
          LeadFamilyControllerTest LeadICEmailSenderTest LeadICScheduleTokenStamperTest \
          PDSchedulerHandlersTest SchedulingEmailSenderTest ZoomMeetingManagerTest \
  --target-org ZenithDev2 \
  --wait 60
```

### 6.7 Destructive changes (informational)

`destructive/destructiveChanges.xml` carries items from a prior release (`pdTimeslotPicker`, `PDAvailabilityController`, `Opportunity.Assigned_PD__c`). v14 does **not** introduce new destructive changes. Confirm those items are already absent from the target org; otherwise append the destructive manifest:

```bash
sf project deploy start \
  --manifest manifest/package.xml \
  --post-destructive-changes destructive/destructiveChanges.xml \
  --target-org ZenithProd \
  --test-level RunLocalTests
```

---

## 7. Post-Deployment Configuration & Validation

### 7.1 Configuration checklist

- [ ] **Named Credential** `Zoom_App` authenticates — Setup → Named Credentials → click `Zoom_App` → "Test Endpoint" returns 200
- [ ] **Slack_Config__mdt** has ≥ 1 active default record with valid `Webhook_URL__c` and `Channel_Name__c`
- [ ] **All v14 flows are Active** — Setup → Flows → confirm:
  - `Lead_Auto_Convert` — Active
  - `Lead_Manual_Convert_Extras` — Active
  - `Lead_Company_AutoFill_Before_Save` — Active
  - `Cancellation_of_Scheduled_Meeting` — Active (screen flow used via QA)
  - `Opportunity_Name_From_Student_OCR` — Active
  - `PD_Book_SOM_Call` — Active (latest version)
  - `Create_Meeting_Zoom_Link_And_Send_Reminders` — Active (latest version)
  - `Lead_Generate_IC_Schedule_Token` — Active (latest version)
  - `Zoom_Meeting_Update_Or_Cancel` — Active (latest version)
- [ ] **URL replacement (§4)** verified by spot-checking one PD-link generation and one IC-link email content
- [ ] **Lead status** `IC Completed – Qualified` and `Converted (SOM Scheduled)` exist
- [ ] **Lead Conversion field map** updated to map Lead.Parent_1_ID__c / Parent_2_ID__c / Student_ID_1__c / 2 / 3 to the correct Contact field (or rely on `Lead_Manual_Convert_Extras` flow)

### 7.2 Lightning UI surfacing (manual)

These are not in metadata and must be added by an admin:

- [ ] **Lead record page** — open in Lightning App Builder, drag in:
  - `leadStudentManager` (in a Field Section labelled "Students")
  - `leadParentGuardianManager` (in a Field Section labelled "Parents / Guardians")
  - Save and Activate (apply to PD/FSS profiles or org-default)
- [ ] **Opportunity record page** — drag in `opportunityPipeline` (suggested: top of right column)
- [ ] **Lead page layout / highlights panel** — add Quick Action **Send IC Scheduling Link**
- [ ] **Opportunity page layout / highlights panel** — add Quick Action **Book Meeting**
- [ ] (Optional) Add `leadStudentManager` and `leadParentGuardianManager` as **Lightning Record Actions** so they can also be opened modal-style
- [ ] (Optional) Add a layout button or QA on Service Appointment that launches `Cancellation_of_Scheduled_Meeting`

### 7.3 Permissions

Verify the user profiles that should run the new functionality have:

- **Apex class access** — `LeadFamilyController`, `OpportunityPipelineController`, `LeadAutoConvert`, `LeadAutoConvertQueueable`, `SchedulingEmailSender`, `GuestSchedulerController`
- **Field-level security** — read/edit on the 8 new fields in §2.4 for any profile that uses the LWCs
- **Record type access** — Account "Family", Contact "Parent" and "Student"
- **Lead status access** — ability to set `IC Completed – Qualified` (typically PD/FSS profiles)

### 7.4 Smoke test scripts

Run every script and check the expected result.

#### Test 1 — Lead Student Manager

| # | Step | Expected |
|---|---|---|
| 1 | Open a test Lead with `No_of_Student_Enrolling_Today__c = 2` | Page loads, "Add Student" button visible |
| 2 | Click **Add Student**, enter First/Last/Grade/Email, Save | Row appears with `Student_ID_1__c = "S-XXXXXXXX"` populated on the Lead |
| 3 | Click **Add Student** a second time | Allowed (cap = 2) |
| 4 | Click **Add Student** a third time | Disabled / blocked with cap message |
| 5 | Edit a row, change First Name, Save | Row updated, ID **unchanged** |
| 6 | Delete a row | Row removed, `Student_ID_N__c` cleared |

#### Test 2 — Lead Parent / Guardian Manager

| # | Step | Expected |
|---|---|---|
| 1 | Open the same Lead | Primary parent block shows current Lead First/Last/Email |
| 2 | Add Second Adult, set Type = `Guardian`, fill First/Last/Email, Save | `Parent_2_ID__c` populated, `Second_Adult_Type__c = Guardian` |
| 3 | Refresh page | Both rows persist |

#### Test 3 — Lead Auto-Convert (asynchronous)

| # | Step | Expected |
|---|---|---|
| 1 | On the Lead, set Status = `IC Completed – Qualified`, Save | Lead saved without error |
| 2 | Wait ≤ 60 s, refresh | Lead `IsConverted = true`; Status = `Converted (SOM Scheduled)`; Account, Parent Contact(s), Student Contact(s), Opportunity all created |
| 3 | Open the Account | Record Type = `Family` |
| 4 | Open Parent Contact | Record Type = `Parent`, `Parent_ID__c` matches `Lead.Parent_1_ID__c` |
| 5 | Open Student Contact | Record Type = `Student`, `Student_ID__c` matches `Lead.Student_ID_1__c` |
| 6 | Open the Opportunity | StageName = `Ready to Schedule SOM`; primary Opportunity Contact Role is the Student |

#### Test 4 — Manual Convert path (`Lead_Manual_Convert_Extras`)

| # | Step | Expected |
|---|---|---|
| 1 | Set Lead Status = `Working` (or any non-trigger status); use the standard **Convert** button | Standard convert wizard runs; Account/Contact/Opp created |
| 2 | Refresh records | `Contact.Parent_ID__c` / `Student_ID__c` populated by `Lead_Manual_Convert_Extras` |

#### Test 5 — Opportunity Pipeline LWC

| # | Step | Expected |
|---|---|---|
| 1 | On an Opportunity, change Stage via the LWC to a new value | Stage and `Pipeline_Group__c` update together |
| 2 | Use the optional "advance to" parameter | StageName ends on the second value; Pipeline_Group_​_c ends on the second group |

#### Test 6 — Book Meeting QA on Opportunity (six paths)

For each path below, run from the **Book Meeting** quick action:

| Path | Pre-condition | Expected end-screen |
|---|---|---|
| First SOM | Opp without an existing first-SOM SA | "Your Meeting is scheduled!" with link to SA |
| Follow-Up 30 min | Opp with PD assigned and a previous SOM | Same success screen |
| PD Scheduling Link — Send | Opp without PD-Scheduling-Link populated | "Email Sent" screen; `Opportunity.PD_Scheduling_Link__c` populated; email delivered |
| PD Scheduling Link — Generate only | Same | "Link Generated" screen; field populated; **no email** |
| FSS Onboarding link | Opp Stage = `Contract Signed`, FSS unassigned or no FSS meeting yet | FSS link generated/sent |
| FSS Follow-Up | Opp Stage = `Contract Signed`, FSS already assigned and FSS meeting exists | FSS Follow-Up SA + Event created on FSS calendar |

#### Test 7 — Send IC Scheduling Link QA on Lead

| # | Step | Expected |
|---|---|---|
| 1 | Run QA on a Lead without `IC_Schedule_Token__c` | Token + link stamped, email delivered with link |
| 2 | Re-run QA | No regeneration; existing link reused |

#### Test 8 — Cancellation of Scheduled Meeting flow

| # | Step | Expected |
|---|---|---|
| 1 | From a Service Appointment with status `Scheduled`, launch the flow | Cancellation reason field shown |
| 2 | Submit | `Status = Canceled`, `Cancellation_Reason__c` populated, `Date_Time_Cancelled__c` stamped, cancellation email sent to the Contact |

#### Test 9 — Public booking site

| # | Step | Expected |
|---|---|---|
| 1 | Open the production booking URL with a valid token | Calendar renders |
| 2 | Pick a slot | SA created, Zoom meeting created via Named Credential, confirmation email + ICS attachment delivered |
| 3 | Click reschedule link in email | Reschedule UI loads, time change updates SA |
| 4 | Click cancel link | SA cancelled |

#### Test 10 — Zoom integration

| # | Step | Expected |
|---|---|---|
| 1 | Confirm any of Tests 6 / 9 above | Zoom meeting appears in host's Zoom account; Join URL is on the SA |

---

## 8. Risk Register

| ID | Risk | Likelihood | Impact | Mitigation | Owner |
|---|---|---|---|---|---|
| R1 | Sandbox URLs deployed to Production unchanged | High if §4 missed | High (broken booking emails) | §4 procedure; spot-check in §7.1 | Release engineer |
| R2 | `Zoom_App` Named Credential missing or expired | Medium | High (no Zoom meetings created) | §3.3 query (A); test in §7.1 | Salesforce admin |
| R3 | `Slack_Config__mdt` missing default record | Medium | Medium (Slack notifications silently skipped) | §3.3 query (B); §7.1 | Salesforce admin |
| R4 | Account "Family" / Contact "Parent" / "Student" record types missing | Low–Medium | High (`LeadAutoConvert` aborts) | §3.3 query (C); pre-flight checklist | Salesforce admin |
| R5 | Lead status `IC Completed – Qualified` not configured | Low | High (auto-convert never triggers) | §3.3 query (D) | Salesforce admin |
| R6 | Lead Conversion field map incomplete for the 5 new ID fields | Medium | Low (extras flow compensates) | §7.1 final item | Salesforce admin |
| R7 | `PD_Book_SOM_Call` regression (1,400-line diff) | Medium | High | Run all 6 paths in Test 6 | QA |
| R8 | Production org-wide Apex coverage < 75 % after deploy | Low | High (deploy fails) | New tests target ≥ 80 % on new code; run coverage report in sandbox first | QA |
| R9 | Field Service config gap (missing WTG / OperatingHours) | Low–Medium | Medium (some booking paths error) | §3.3 query (E); Test 6 | Salesforce admin |
| R10 | Lightning Record Pages not updated post-deploy | Low | Medium (LWCs deployed but invisible) | §7.2 manual checklist | Salesforce admin |

---

## 9. Rollback Plan

> Most v14 changes are additive. Forward-fix is generally faster than full rollback.

### 9.1 Decision matrix

| Failure | Rollback action |
|---|---|
| Single Apex/LWC bug found post-deploy | Hot-fix on `release/v14-prod`, redeploy that one component |
| `Lead_Auto_Convert` causing bad conversions | Deactivate the flow in Setup → Flows (no code rollback needed); investigate; redeploy a fixed version |
| Major regression across multiple components | Full rollback per §9.2 |

### 9.2 Full rollback procedure

```bash
# 1. Switch to v13 (last known-good)
git checkout v13

# 2. Re-deploy v13 source — this restores prior Apex / LWC / Flow versions
sf project deploy start \
  --source-dir force-app \
  --test-level RunLocalTests \
  --target-org ZenithProd \
  --wait 60

# 3. In Setup → Flows, activate the prior version of any flow whose latest
#    (v14) version remains activated after step 2 — Salesforce keeps
#    older flow versions; "activate previous" is a one-click action.

# 4. (Optional) Remove the 8 new custom fields if they cause issues.
#    Build a destructive-changes manifest and deploy:
cat > /tmp/destructiveChanges.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
  <types>
    <members>Lead.Parent_1_ID__c</members>
    <members>Lead.Parent_2_ID__c</members>
    <members>Lead.Second_Adult_Type__c</members>
    <members>Lead.Student_ID_1__c</members>
    <members>Lead.Student_ID_2__c</members>
    <members>Lead.Student_ID_3__c</members>
    <members>Contact.Parent_ID__c</members>
    <members>Contact.Student_ID__c</members>
    <name>CustomField</name>
  </types>
  <version>66.0</version>
</Package>
EOF
# (Empty package.xml required alongside destructive changes — see Salesforce docs.)
```

> **Field rollback is rarely needed** — empty Text fields are harmless. Prefer leaving them in place.

### 9.3 Data rollback

Lead Auto-Convert mutates real records (Lead → Account/Contact/Opp). If a bad conversion runs in production:

1. Identify affected records by `Opportunity.LeadId__c` from the rollback window.
2. Use a recycle-bin restore for accidentally deleted Leads, or a Data Loader-based "undo" for created records.
3. Note that `Lead.IsConverted` cannot be reversed; if the conversion itself was wrong, recreate the Lead from a backup.

> Recommendation: take a Data Export of `Lead`, `Account`, `Contact`, `Opportunity`, and `OpportunityContactRole` immediately before the prod deploy.

---

## 10. Communication & Cutover Plan

| When | Audience | Channel | Message |
|---|---|---|---|
| T-3 days | All Sales / FSS / PD users | Email + Slack | "v14 deploy scheduled for `<date>`; expect 30–45 min downtime in critical workflows" |
| T-1 day | Same | Slack | "Reminder: deploy tomorrow at `<time>`" |
| T-0 start | Operations team | Slack `#deployments` | "Production deploy starting" |
| T-0 end | All users | Email + Slack | "v14 deploy complete; new features: Family Manager, Pipeline LWC, Auto-Convert. See attached release notes." |
| T+1 day | Stakeholders | Email | Summary of issues found, smoke-test results, sign-off |

---

## 11. Sign-Off

| Stage | Owner | Status | Date |
|---|---|---|---|
| Pre-flight checklist (§3) complete |  | ☐ |  |
| URL replacement (§4) committed and reviewed |  | ☐ |  |
| Sandbox / UAT deploy (§6.2) green |  | ☐ |  |
| UAT smoke tests (§7.4) passed |  | ☐ |  |
| Production validation (§6.3) green |  | ☐ |  |
| Production quick-deploy (§6.4) green |  | ☐ |  |
| Post-deploy config (§7.1–7.3) complete |  | ☐ |  |
| Production smoke tests (§7.4) passed |  | ☐ |  |
| Client sign-off |  | ☐ |  |

---

## 12. Open Questions for Client

1. **Production booking site URL** — what value should replace `https://site-enterprise-6958--dev2.sandbox.my.site.com/booking`?
2. **Production Lightning base URL** — what value should replace `https://site-enterprise-6958.lightning.force.com`?
3. **Target org alias** for Production (and intermediate UAT sandbox if used)?
4. **Deployment window** — preferred date and time, including freeze period for non-critical work?
5. Confirm each item in **§3.1** and **§3.2** is already configured in Production. Anything missing should be staged ahead of the cutover.
6. Approval to proceed with the **Custom Label refactor** of the booking URL in v15 (recommended)?
7. Who is the **business owner** signing off on each smoke-test scenario (§7.4)?
8. Should the `Opportunity_Name_From_Student_OCR` flow run **only on new** Opportunities or also retrofit existing ones (one-time data fix)?

---

## Appendix A — Repository File Manifest

```
DEPLOYMENT_PLAN_v14.md                        ← this document
manifest/package.xml                          ← retrieve manifest
destructive/destructiveChanges.xml            ← carries v13 destructions
sfdx-project.json                             ← SFDX config
.forceignore                                  ← exclusions

force-app/main/default/
├── classes/                                  19 production + 9 test Apex classes
├── flows/                                    14 flows
├── lwc/                                      6 LWCs (4 exposed)
├── objects/Lead/fields/                      6 new fields (§2.4)
├── objects/Contact/fields/                   2 new fields (§2.4)
├── objects/Account|Opportunity|ServiceAppointment|ServiceResource/   pre-existing
├── quickActions/                             Lead.Send_IC_Schedule_Link, Opportunity.Book_Meeting
├── email/Scheduling_Templates/               3 templates
└── letterhead/                               Zenith Prep Classic
```

## Appendix B — Reference Commands

```bash
# Set default org
sf config set target-org=ZenithProd

# Inspect what will deploy
sf project deploy preview --source-dir force-app --target-org ZenithProd

# Generate a manifest of only changed files since v13 (for a minimal package)
sf project generate manifest \
  --source-dir force-app \
  --output-dir manifest \
  --name v14-only

# Code coverage report
sf apex run test --target-org ZenithProd --code-coverage --result-format human

# Tail debug logs during smoke test
sf apex tail log --target-org ZenithProd --color
```

## Appendix C — Useful Setup Paths

| Task | Path |
|---|---|
| Named Credentials | Setup → Security → Named Credentials |
| Custom Metadata records | Setup → Custom Code → Custom Metadata Types |
| Flow activation / version history | Setup → Process Automation → Flows |
| Apex test runs | Setup → Custom Code → Apex Test Execution |
| Deployment status | Setup → Environments → Deploy → Deployment Status |
| Lead Conversion field map | Setup → Object Manager → Lead → Map Lead Fields |
| Lightning Record Page editor | Setup → Object Manager → `<Object>` → Lightning Record Pages → Edit → Lightning App Builder |

---

*End of document.*
