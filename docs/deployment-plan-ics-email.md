# Deployment Plan — ICS Calendar Invites & Email Notifications

**Source branch:** `v19` &nbsp;|&nbsp; **Target:** Production &nbsp;|&nbsp; **Owner:** solutions@cloudsheer.com &nbsp;|&nbsp; **Date:** 2026-05-13

## 1. Scope

End-to-end Zoom + ICS + email pipeline for Service Appointments (IC, PD/SOM, FSS):

- Booking confirmation emails with `.ics` calendar attachment (METHOD:REQUEST)
- Reschedule emails with updated `.ics` (same UID, incremented SEQUENCE)
- Cancellation emails with `.ics` (METHOD:CANCEL)
- Host-side notifications with METHOD:PUBLISH `.ics` + Salesforce Event for EAC sync
- No-show notifications
- Pre-meeting reminders (86h / 48h / 8h / 2h)
- Scheduling-link outbound emails (IC/PD/FSS) with branded OWEA + family CC

---

## 2. Pre-Deployment Setup in Production (manual, before metadata deploy)

These items **cannot** be deployed via metadata API and must exist first, or the Apex/Flows will fail at runtime.

### 2.1 Org-Wide Email Address (OWEA)

| Setting | Value |
|---|---|
| Display Name | Zenith Prep Academy |
| Email Address | `info@zenithprepacademy.com` |
| Allow All Profiles | Yes |
| Status | Verified (click verification link) |

Referenced in: `SchedulingEmailSender.cls`, `LeadICEmailSender.cls`, `ZoomMeetingManager.cls`.

### 2.2 Zoom Named Credential / Connected App

- Named Credential: `Zoom_API` (Server-to-Server OAuth — Client ID, Client Secret, Account ID)
- Auth provider configured per Zoom marketplace app

### 2.3 Einstein Activity Capture (EAC)

- Enable EAC for host users (Program Directors, Admissions Counselors, FSS, ES) so the `Event` created by `ensureHostEvent` syncs to their Google/Outlook calendar.

### 2.4 Remote Site Settings

- `https://api.zoom.us`
- `https://zoom.us`

### 2.5 Salesforce Site (Guest Scheduler)

- Site must already serve `/booking` page (Booking_Site_Base_URL Custom Label points here).
- Guest user profile assigned to the site.

---

## 3. Metadata Components to Deploy

### 3.1 Custom Labels

| Label | Required Value |
|---|---|
| `Booking_Site_Base_URL` | `https://zenithprepacademy.my.site.com` (prod URL) |
| `Booking_Token_Encryption_Key_Hex` | 64-char hex AES-256 key (rotate from sandbox) |

> **Action:** Generate a NEW production AES key. Do NOT reuse sandbox key.

### 3.2 Custom Fields

**ServiceAppointment** (`force-app/main/default/objects/ServiceAppointment/fields/`)

| Field | Type | Purpose |
|---|---|---|
| `Zoom_Meeting_ID__c` | Text(20) | Zoom meeting id |
| `Zoom_Join_URL__c` | URL(255) | Customer join link |
| `Zoom_Link__c` | URL(255) | Legacy/alt join link |
| `Zoom_Start_URL__c` | URL(2048) | Host start link |
| `Cal_UID__c` | Text(255) | ICS UID for calendar threading |
| `Reschedule_Token__c` | Text(255) | One-time reschedule token |
| `Reschedule_URL__c` | Formula(URL) | `/booking?reschedule=…` |
| `Cancel_URL__c` | Formula(URL) | `/booking?cancel=…` |
| `Is_Rescheduled__c` | Checkbox | Flipped by `SA_Mark_Rescheduled_On_Time_Change` |
| `Cancellation_Reason__c` | Picklist | Required when Status=Canceled |
| `Date_Time_of_Cancellation__c` | DateTime | Set on cancel |
| `Attendance_Status__c` | Picklist | Attended / No Show / etc. |
| `Appointment_Status_Custom__c` | Picklist | Custom status surface |
| `Meeting_Type__c` | Picklist | IC / SOM / FSS |
| `Lead__c` | Lookup(Lead) | Polymorphic anchor for Lead-based SA |
| `Opportunity__c` | Lookup(Opportunity) | Anchor for converted SA |
| `Admission_Counselor__c`, `Admission_Counselor_Name__c` | Lookup / Text | Host resolution |
| `Educational_Strategist__c`, `Educational_Strategist_Name__c` | Lookup / Text | Host resolution |
| `Program_Director__c` | Lookup(User) | Host resolution |
| `Family_Success_Specialist__c` | Lookup(User) | Host resolution |
| `Student__c` | Lookup(Contact) | Student contact |
| `Student_First_Name__c`, `Student_Full_Name__c`, `Student_Grade__c` | Formula | Template merge |
| `Customer_Name__c` | Formula | Template merge |
| `Sched_Start_Local__c`, `Meeting_Start_Time_text__c`, `ScheduleStartTimeText__c`, `Scheduled_Start_Display__c` | Formula | Time display in templates |
| `Timezone_Abrev__c`, `Timezone_Offset__c`, `DST__c` | Formula | ICS TZ conversion |
| `Landing_Page_Source__c`, `Is_Duplicate_Family__c` | Text/Checkbox | Marketing/dedup |
| `Meeting_Notes__c` | Long Text | Post-meeting notes |

**Lead** (relevant fields)

- `IC_Schedule_Link__c`, `IC_Schedule_Token__c`, `IC_Reschedule_Link__c`, `IC_Reschedule_Token__c`
- `IC_Meeting_Rescheduled__c`, `IC_No_Show_Count__c`
- `Parent_1_Email__c`, `Parent_2_Email__c`, `Student_Email__c`, `Guest_Emails__c`
- `Service_Appointment__c` (lookup back to most recent SA)
- `Meeting_Status__c`, `Scheduled_Meeting_DateTime__c`

**Opportunity** (relevant fields)

- `PD_Scheduling_Link__c`, `PD_Link_Used_At__c`
- `FSS_Scheduling_Link__c`, `FSS_Link_Used_At__c`
- `SO_Meeting_Rescheduled__c`, `SOM_No_Show_Count__c`, `SOM_DateTime__c`

**Event** (standard object, custom field)

- `Service_Appointment__c` — Lookup(ServiceAppointment), used by `Sync_service_appointment_to_calendar` and `ZoomMeetingManager.ensureHostEvent`

**Contact** — `Record_Type__c` picklist (`Parent`, `Student`), `Parent_Verified__c`, `Parent_ID__c`, `Student_ID__c`

**ServiceResource** — `Resource_Type__c`, `Active__c`, `Weight__c`, `Appointment_Count__c`

### 3.3 Validation Rules

- `ServiceAppointment.Cancellation_Reason_is_Required` — blocks save when `Status=Canceled` and `Cancellation_Reason__c` is blank.

### 3.4 Apex Classes (deploy together — interdependent)

| Class | Role |
|---|---|
| `ZoomMeetingManager` | Master orchestrator (CREATE / RESCHEDULE / CANCEL) |
| `ZoomMeetingService` | Zoom REST wrapper |
| `ZoomMeetingEmailService` | Email send + ICS attachment |
| `ZoomIcsBuilder` | RFC 5545 ICS body builder |
| `ZoomMeetingCancelEmailAction` | Invocable cancel-email entry point |
| `LeadICEmailSender` | IC scheduling-link send (Lead) |
| `SchedulingEmailSender` | PD/FSS scheduling-link send (Opportunity) |
| `LeadICScheduleTokenStamper` | Lead conversion token stamping |
| `RescheduleTokenService` | Reschedule token mint/validate |
| `BookingTokenUtil` | AES token encrypt/decrypt |
| `GuestSchedulerController` | Guest-site booking controller |
| `PDPostBookingHandler` | Post-SOM SA wiring |
| `PDSchedulingConfigHandler` | PD/FSS scheduling-link config |
| **Test classes (all required for 75% prod coverage)** | `ZoomMeetingManagerTest`, `LeadICEmailSenderTest`, `SchedulingEmailSenderTest`, `BookingTokenUtilTest`, `GuestSchedulerControllerTest`, `LeadICScheduleTokenStamperTest`, `PDSchedulerHandlersTest`, `RescheduleTokenServiceTest` |

### 3.5 Flows (deploy as Active)

| Flow | Object / Trigger | Purpose |
|---|---|---|
| `Service_Appointment_Status_Change_Email_Notification` | SA / RecordAfterSave | Routes cancel (client vs staff) / reschedule / no-show email branches |
| `Create_Meeting_Zoom_Link_And_Send_Reminders` | Scheduled-triggered | Generates Zoom link + sends 86h/48h/8h/2h reminders |
| `SA_Mark_Rescheduled_On_Time_Change` | SA / RecordBeforeSave | Sets `Is_Rescheduled__c = true` on time change |
| `Sync_service_appointment_to_calendar` | SA / RecordAfterSave (insert) | Creates host Event so EAC syncs to host calendar |

### 3.6 Email Templates (Lightning, `EmailTemplate` metadata)

Must exist in prod with **identical Developer Names** — referenced by hardcoded strings in Apex/Flows.

**Scheduling-link emails** (Apex):

- `IC_Scheduling_Link_Send_Email`
- `PD_Scheduling_Link_Send_Email`
- `FSS_Scheduling_Link_Send_Email`

**Booking/Reschedule/Cancel** (Apex — `ZoomMeetingManager`):

- `Meeting_Schedule_Email_Template_1765244752004` (booking confirmation)
- `Meeting_Rescheduled_Send_Email`
- `Meeting_Cancelled_Send_Email`
- `Initial_Consultation_Meeting_Scheduled`
- `Meeting_After_RTF`

**Flow-side templates** (`Service_Appointment_Status_Change_Email_Notification`):

- `Meeting_Cancelled_by_Client_Email_Template_1765299787160`
- `Meeting_Cancelled_by_Educational_Strategist_Email_Template_1765299931137`
- `Meeting_Rescheduled_Email_Template_1777159570088`
- `Family_No_Showed_Email_Template_1765300085527`

**Reminders** (`Create_Meeting_Zoom_Link_And_Send_Reminders`):

- `X86_Hours_Prior_to_Scheduled_Meeting_Email_Template_1765245833404`
- `X48_Hours_Prior_to_Scheduled_Meeting_Email_Template_1777031949438`
- `X8_Hours_Prior_to_Scheduled_Meeting_Email_Template_1765245884943`
- `X2_Hours_Prior_to_Scheduled_Meeting_Email_Template_1777036457115`

> **Action:** Verify each template's enhanced letterhead, sender (OWEA), and merge fields render in prod context before activating flows.

### 3.7 Layouts / List Views / Compact Layouts

- `ServiceAppointment` — Compact Layout (`Meeting_Compact_Layout`), All / MyPending / MyScheduled / My_Meetings list views
- `Lead-Lead Layout`
- `Opportunity-Opportunity Layout`, `Opportunity-Opportunity Contact Role Layout`

### 3.8 Skills / Skill Types (for resource matching)

- Skills: `Admissions_Counselor`, `Educational_Strategist`, `Program_Director`, `FSS_Onboarding`
- SkillTypes: same four

### 3.9 Standard Value Sets

- `OpportunityStage` (new values)
- `ContactRole` (new values)

---

## 4. Profile / Permission Set Configuration

### 4.1 Object-Level Access

| Profile | ServiceAppointment | Event | Lead | Opportunity | Contact | OperatingHours / ServiceResource |
|---|---|---|---|---|---|---|
| Admin | Full | Full | Full | Full | Full | Full |
| Program Director | CRU + View All | CRU | R/U | R/U/Owner | R/U | R |
| Admission Counsellor | CRU + View All | CRU | CRU | R/U | R/U | R |
| FSS Onboarding | CRU + View All | CRU | R | R/U/Owner | R/U | R |
| Guest License User | C (booking only) | none | C | R | C | R |

Profile metadata for all roles is in `force-app/main/default/profiles/` (28 profile files modified).

### 4.2 Field-Level Security

Grant **Read + Edit** on the fields in §3.2 to: Admin, Program Director, Admission Counsellor, FSS Onboarding, Zenith Hub Admin, Zenith Booking Profile.

Guest License User needs **Read** on: `Zoom_Join_URL__c`, `Reschedule_URL__c`, `Cancel_URL__c`, `Cal_UID__c`, all SA time + display fields.

### 4.3 Apex Class Access

Grant access to all 13 classes in §3.4 for Admin, Program Director, Admission Counsellor, FSS Onboarding, Zenith Booking Profile, Guest License User (for the guest-callable controllers only: `GuestSchedulerController`, `BookingTokenUtil`, `RescheduleTokenService`).

### 4.4 Flow Access

All four flows in §3.5 are `AutoLaunchedFlow` / record-triggered — no flow user permission needed beyond the running user's object access.

---

## 5. Deployment Steps (Production)

| # | Step | Owner | Reversible? |
|---|---|---|---|
| 1 | Backup prod metadata (`sf project retrieve start --manifest …`) | Admin | n/a |
| 2 | Create OWEA `info@zenithprepacademy.com` + verify | Admin | Yes |
| 3 | Create Custom Labels with **prod** values (new AES key) | Admin | Yes |
| 4 | Deploy Apex classes + tests via `sf project deploy start -l RunSpecifiedTests` listing all 8 test classes — confirm ≥ 75% coverage | DevOps | Yes (rollback by redeploy) |
| 5 | Deploy custom fields, validation rule, layouts, compact layouts, list views, skills | DevOps | Yes |
| 6 | Create / upload email templates in prod (or deploy via metadata if held in repo) with identical DeveloperNames | Admin | Yes |
| 7 | Deploy Flows as **Active** (validate each in Flow Builder first) | DevOps | Yes |
| 8 | Deploy profile / FLS changes | Admin | Yes |
| 9 | Configure Zoom Named Credential + Remote Site Settings | Admin | Yes |
| 10 | Smoke test (see §6) on a real test family record | QA | n/a |
| 11 | Activate scheduled-triggered flow `Create_Meeting_Zoom_Link_And_Send_Reminders` | Admin | Yes (deactivate) |

**Deployment window:** off-hours (after 8pm PT) — reminder flow runs hourly and is the only piece with timing sensitivity.

---

## 6. Post-Deployment Smoke Test

1. **IC scheduling email** — convert a test Lead with second-parent + student emails → confirm TO = primary parent, CC = parent 2 + student, FROM = `info@zenithprepacademy.com`.
2. **Book via Guest Scheduler** → confirm:
   - Zoom meeting created (check Zoom dashboard)
   - Customer email delivered with `.ics` attachment, opens cleanly in Gmail + Outlook + Apple Calendar
   - Host email delivered (no "Unable to load event" warning in Gmail)
   - Salesforce `Event` created with `Service_Appointment__c` populated → host's EAC-linked calendar shows the meeting
3. **Reschedule** via reschedule URL → confirm same UID, SEQUENCE incremented, calendar entry updates in place (not duplicated).
4. **Cancel** via cancel URL → confirm METHOD:CANCEL `.ics` removes event from family + host calendar.
5. **No-show**: set `Attendance_Status__c = No Show` → confirm no-show template fires from `Service_Appointment_Status_Change_Email_Notification`.
6. **Reminders**: book a meeting 87h out → check reminder cadence (86h/48h/8h/2h).
7. **Activity timeline**: confirm emails attach to Opportunity (FSS/PD) and Lead (IC) timelines.

---

## 7. Rollback Plan

| Failure | Rollback |
|---|---|
| Apex deploy fails | `sf project deploy start --manifest backup.xml` (re-deploy pre-deploy snapshot) |
| Email storm / wrong sender | Deactivate `Service_Appointment_Status_Change_Email_Notification` + `Create_Meeting_Zoom_Link_And_Send_Reminders` flows via Setup → Flows |
| Zoom API exhausted | Set Named Credential to disabled; `ZoomMeetingManager` swallows API errors and still sends ICS-based fallback |
| Bad AES key | Rotate `Booking_Token_Encryption_Key_Hex` Custom Label; existing reschedule/cancel tokens invalidate (acceptable for a same-day rotation) |
| Template missing in prod | Templates referenced by DeveloperName — Apex falls back to Apex-built body; flow path will error → deactivate flow node |

---

## 8. Known Risks / Watch-outs

- **OWEA verification** must complete before step 4 or emails silently fall back to running user's address.
- **EAC license** required on every host user; without it, host Event syncs but the host's external calendar will not.
- **Sandbox AES key** must NOT be reused — historic tokens would remain valid in prod.
- **`Sync_service_appointment_to_calendar`** only fires on SA insert with ContactId — Lead-based SAs rely on `ZoomMeetingManager.ensureHostEvent` (Apex). Both must deploy together.
- **`Service_Appointment__c` field on Event** is custom and must exist before `Sync_service_appointment_to_calendar` is activated.
- **METHOD:PUBLISH host ICS** (introduced v22) requires Gmail/Outlook to treat the host as receiver — relies on `Cal_UID__c` matching the SF Event's EAC-derived UID for dedupe.

---

## 9. Sign-off Checklist

- [ ] OWEA verified
- [ ] Custom Labels created (new prod AES key)
- [ ] All 13 Apex classes deployed, 75% coverage
- [ ] 4 flows deployed and Active
- [ ] All email templates present with correct DeveloperNames
- [ ] FLS granted for all custom fields per §4.2
- [ ] Zoom Named Credential connected
- [ ] Smoke test §6 passed end-to-end
- [ ] Stakeholders (PD/AC/FSS leads) notified of go-live
