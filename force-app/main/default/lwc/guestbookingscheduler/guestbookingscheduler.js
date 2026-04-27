import { LightningElement, api, track } from 'lwc';
import getBookingConfig  from '@salesforce/apex/GuestSchedulerController.getBookingConfig';
import getAvailableSlots from '@salesforce/apex/GuestSchedulerController.getAvailableSlots';
import bookAppointment   from '@salesforce/apex/GuestSchedulerController.bookAppointment';

const MONTHS = ['January','February','March','April','May','June',
    'July','August','September','October','November','December'];

export default class GuestBookingScheduler extends LightningElement {

    @api openWindowDays = 8;
    @api redirectUrl = 'https://www.zenithprepacademy.com/before-your-consultation-video';
    @api bookingType = '';

    @track isLoading = true;
    @track isReady = false;
    @track hasFatalError = false;
    @track fatalErrorDetail = '';
    @track isLinkAlreadyUsed = false;
    @track isCancelMode = false;
    @track isRescheduling = false;
    @track originalStartDisplay = '';
    @track originalStartCompact = '';
    @track currentStep = 1;
    @track isSlotsLoading = false;
    @track isSubmitting = false;

    config = {};
    clientTimezone = 'America/Chicago';
    utmSource = ''; utmCampaign = ''; utmMedium = ''; utmAd = ''; utmAdSet = '';
    leadSource = '';
    _contactId = '';
    _opportunityId = '';
    _resolvedType = '';
    _token = '';
    _action = '';
    _rescheduleToken = '';

    @track calYear = 0;
    @track calMonth = 0;
    @track calendarDays = [];
    @track selectedDate = null;
    availableDateSet = new Set();
    lastAvailableDate = null;

    @track timeSlots = [];
    @track selectedStart = null;
    @track selectedEnd = null;

    @track firstName = '';
    @track lastName = '';
    @track email = '';
    @track phone = '';
    @track studentGrade = '';
    @track confirm1 = '';
    @track confirm2 = '';
    @track guestEmailList = [];
    @track newGuestEmail = '';
    @track guestError = '';
    @track consentChecked = false;
    @track validationError = '';
    // Toggled true on the first submit attempt. Per-field error getters key
    // off this so the form stays clean until the user clicks "Confirm meeting"
    // once — then errors appear inline next to each invalid field, not at
    // the bottom of the form.
    @track submitAttempted = false;
    // Confirm-page action buttons (Add to calendar / Reschedule / Cancel)
    // were removed — the confirmation email already carries those links, so
    // the in-page buttons were redundant. Apex still returns rescheduleUrl /
    // cancelUrl on bookAppointment for the Lead/SA URL formula fields and
    // the email service; we just don't surface them in the LWC anymore.

    // Optional counselor display in the Step-2 sidebar. Only populated when the
    // backend hands us a name (e.g. reschedule flow with the original Owner).
    @track _counselorDisplayName = '';
    @track _counselorFirstName = '';
    @track _counselorRole = '';

    // Deprecated IANA timezone names that browsers may still return
    static TZ_ALIASES = {
        'Asia/Calcutta':        'Asia/Kolkata',
        'Asia/Saigon':          'Asia/Ho_Chi_Minh',
        'Asia/Katmandu':        'Asia/Kathmandu',
        'Asia/Rangoon':         'Asia/Yangon',
        'Pacific/Ponape':       'Pacific/Pohnpei',
        'Pacific/Truk':         'Pacific/Chuuk',
        'Atlantic/Faeroe':      'Atlantic/Faroe',
        'Europe/Kiev':          'Europe/Kyiv',
        'America/Buenos_Aires': 'America/Argentina/Buenos_Aires'
    };

    connectedCallback() {
        try {
            let tz = Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/Chicago';
            this.clientTimezone = GuestBookingScheduler.TZ_ALIASES[tz] || tz;
        } catch (_) {}
        this._action = (this._getUrlParam('action') || '').toLowerCase();
        const urlToken = this._getUrlParam('token') || '';

        if ((this._action === 'reschedule' || this._action === 'cancel') && urlToken) {
            this._rescheduleToken = urlToken;
        } else {
            this._token = urlToken;
        }

        if (this._action === 'cancel' && this._rescheduleToken) {
            this.isCancelMode = true;
            this.isLoading = false;
            return;
        }

        this._resolvedType = this.bookingType || this._getUrlParam('type') || '';
        this._contactId = this._getUrlParam('contactId') || '';
        this._opportunityId = this._getUrlParam('opportunityId') || '';
        this.utmSource = this._getUrlParam('utm_source');
        this.utmCampaign = this._getUrlParam('utm_campaign');
        this.utmMedium = this._getUrlParam('utm_medium');
        this.utmAd = this._getUrlParam('utm_ad');
        // Accept both common spellings for the ad-set param.
        this.utmAdSet = this._getUrlParam('utm_adset') || this._getUrlParam('utm_ad_set');
        this.leadSource = this._getUrlParam('lead_source') || 'Website';

        this._init();
    }

    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get step1NodeClass() {
        if (this.currentStep > 1) return 'step-node complete';
        if (this.currentStep === 1) return 'step-node active';
        return 'step-node';
    }
    get step2NodeClass() {
        if (this.currentStep > 2) return 'step-node complete';
        if (this.currentStep === 2) return 'step-node active';
        return 'step-node';
    }
    get step3NodeClass() {
        if (this.currentStep === 3) return 'step-node active';
        return 'step-node';
    }
    get isStep1Complete() { return this.currentStep > 1; }
    get isStep2Complete() { return this.currentStep > 2; }
    get connector1Class() { return this.currentStep > 1 ? 'step-line complete' : 'step-line'; }
    get connector2Class() { return this.currentStep > 2 ? 'step-line complete' : 'step-line'; }
    get hasSlots() { return !this.isSlotsLoading && this.timeSlots.length > 0; }
    get noSlotsForDate() { return !this.isSlotsLoading && this.selectedDate && this.timeSlots.length === 0; }
    get noDateSelected() { return !this.selectedDate; }
    get currentMonthLabel() { return `${MONTHS[this.calMonth]} ${this.calYear}`; }

    get prevMonthDisabled() {
        const now = new Date();
        return this.calYear === now.getFullYear() && this.calMonth === now.getMonth();
    }
    get nextMonthDisabled() {
        if (!this.lastAvailableDate) return true;
        return this.calYear > this.lastAvailableDate.getFullYear() ||
            (this.calYear === this.lastAvailableDate.getFullYear()
             && this.calMonth >= this.lastAvailableDate.getMonth());
    }
    get selectedDateLong() {
        if (!this.selectedDate) return '';
        const [y, m, d] = this.selectedDate.split('-');
        return new Date(+y, +m-1, +d).toLocaleDateString('en-US',
            { weekday:'long', month:'long', day:'numeric', year:'numeric' });
    }
    get selectedTimeDisplay() {
        if (!this.selectedStart) return '';
        return new Date(this.selectedStart).toLocaleTimeString('en-US',
            { timeZone: this.clientTimezone, hour:'numeric', minute:'2-digit', hour12:true });
    }
    get timezoneDisplay() {
        try {
            const parts = new Intl.DateTimeFormat('en-US',
                { timeZone: this.clientTimezone, timeZoneName:'long' }).formatToParts(new Date());
            const tzPart = parts.find(p => p.type === 'timeZoneName');
            const offset = -new Date().getTimezoneOffset();
            const sign = offset >= 0 ? '+' : '-';
            const hrs = String(Math.floor(Math.abs(offset)/60)).padStart(2,'0');
            const mins = String(Math.abs(offset)%60).padStart(2,'0');
            return `UTC ${sign}${hrs}:${mins} ${tzPart ? tzPart.value : this.clientTimezone}`;
        } catch (_) { return this.clientTimezone; }
    }
    get durationLabel() {
        if (this._resolvedType === 'FSS') return '30 minutes';
        return '1 hour';
    }
    get isICMode() {
        return !this._resolvedType || this._resolvedType === 'IC';
    }
    get showTwoStepTrack() {
        return this.isICMode && !this.isRescheduling;
    }
    get headerLabel() {
        if (this._resolvedType === 'PD') return 'Program Director Meeting with Zenith Prep Academy';
        if (this._resolvedType === 'FSS') return 'FSS Onboarding Meeting with Zenith Prep Academy';
        return 'Initial Consultation with Zenith Prep Academy';
    }

    // Step-1 error surface (reschedule + PD/FSS book straight from slot click).
    // The HTML references {bookingError}; this maps it to validationError so any
    // failure from bookAppointment becomes visible instead of silently failing.
    get bookingError() { return this.validationError; }
    get showAssignedPdBanner() { return false; }
    get assignedPdDisplay() { return ''; }

    // ── Step-2 form: grade dropdown ───────────────────────────
    // LWC doesn't allow `value` on <select>; mark the chosen <option> with
    // `selected` instead. Preserves existing picklist values (5th–12th).
    get gradeSelectOptions() {
        const all = [
            { value: '',     label: '-- Select grade --' },
            { value: '5th',  label: '5th'  },
            { value: '6th',  label: '6th'  },
            { value: '7th',  label: '7th'  },
            { value: '8th',  label: '8th'  },
            { value: '9th',  label: '9th'  },
            { value: '10th', label: '10th' },
            { value: '11th', label: '11th' },
            { value: '12th', label: '12th' }
        ];
        return all.map(o => ({ ...o, isSelected: this.studentGrade === o.value }));
    }

    // ── Step-2 form: grade button group (legacy chip layout, kept for reuse) ──
    // Display labels match the design (5–6, 7–8, 9, 10, 11, 12) but the
    // submitted value uses an existing picklist entry to avoid breaking the
    // Lead.Student_Grade__c field.
    get gradeOptions() {
        const opts = [
            { label: '5–6',  value: '5th'  },
            { label: '7–8',  value: '7th'  },
            { label: '9',    value: '9th'  },
            { label: '10',   value: '10th' },
            { label: '11',   value: '11th' },
            { label: '12',   value: '12th' }
        ];
        return opts.map(o => ({
            ...o,
            cssClass: this.studentGrade === o.value ? 'grade-btn selected' : 'grade-btn'
        }));
    }

    // ── Step-2 form: guest email chip list ────────────────────
    // The Apex contract still expects a comma-separated string named
    // `guestEmails`. We build it from the array on submit.
    get guestEmails() { return this.guestEmailList.join(', '); }
    get hasGuestEmails() { return this.guestEmailList.length > 0; }
    get noGuestsHelper() { return this.guestEmailList.length === 0; }
    get guestCounterText() { return `${this.guestEmailList.length}/10 guests`; }
    get addGuestDisabled() {
        return this.guestEmailList.length >= 10
            || !(this.newGuestEmail || '').trim();
    }

    // ── Step-2 form: per-field error getters (inline display) ──
    // Each returns an empty string until the user has tried to submit at
    // least once (submitAttempted=true), so the form starts clean. After
    // that, the getter recomputes on every keystroke thanks to LWC
    // reactivity, so a fixed field clears its error live.
    get firstNameError() {
        return this.submitAttempted && !this.firstName.trim() ? 'First name is required.' : '';
    }
    get lastNameError() {
        return this.submitAttempted && !this.lastName.trim() ? 'Last name is required.' : '';
    }
    get emailError() {
        if (!this.submitAttempted) return '';
        const v = (this.email || '').trim();
        if (!v) return 'Email is required.';
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)) return 'Please enter a valid email address.';
        return '';
    }
    get phoneError() {
        return this.submitAttempted && (this.phone || '').replace(/\D/g, '').length < 10
            ? 'Phone number must be at least 10 digits.' : '';
    }
    get studentGradeError() {
        return this.submitAttempted && !this.studentGrade ? 'Please select a student grade.' : '';
    }
    get confirm1Error() {
        return this.submitAttempted && this.confirm1.trim().toLowerCase() !== 'i confirm'
            ? 'Please confirm you will attend the consultation.' : '';
    }
    get confirm2Error() {
        return this.submitAttempted && this.confirm2.trim().toLowerCase() !== 'i confirm'
            ? 'Please acknowledge the limited-availability and rescheduling policy.' : '';
    }
    get consentError() {
        return this.submitAttempted && !this.consentChecked
            ? 'You must agree to receive communications.' : '';
    }

    // ── Step-2 form: confirmation checkboxes ──────────────────
    // The original design used "type 'I confirm'" text inputs. The string
    // value is preserved so _validate() still passes/fails identically.
    get confirm1Checked() { return this.confirm1.trim().toLowerCase() === 'i confirm'; }
    get confirm2Checked() { return this.confirm2.trim().toLowerCase() === 'i confirm'; }
    get confirm1RowClass() {
        return this.confirm1Checked ? 'check-card check-card--checked' : 'check-card';
    }
    get confirm2RowClass() {
        return this.confirm2Checked ? 'check-card check-card--checked' : 'check-card';
    }

    // ── Step-2 form: subtitle + counselor block ───────────────
    get formSubtitle() {
        const fn = (this._counselorFirstName || '').trim();
        return fn
            ? `Just a few details so ${fn} can prepare for your call.`
            : 'Just a few details so we can prepare for your call.';
    }
    get showCounselorBlock() { return !!this._counselorDisplayName; }
    get rescheduleWithCounselor() {
        return this._counselorDisplayName ? ` with ${this._counselorDisplayName}` : '';
    }
    get counselorDisplayName() { return this._counselorDisplayName || ''; }
    get counselorRole() { return this._counselorRole || 'Senior counselor'; }
    get counselorInitials() {
        const n = (this._counselorDisplayName || '').trim();
        if (!n) return '';
        const parts = n.split(/\s+/);
        const first = parts[0] ? parts[0].charAt(0) : '';
        const last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : '';
        return (first + last).toUpperCase();
    }

    // Action-aware copy for the "link already used" error card.
    get linkUsedHeading() {
        if (this._action === 'cancel')     return 'Meeting Already Canceled';
        if (this._action === 'reschedule') return 'Meeting Already Rescheduled';
        return 'Meeting Already Scheduled';
    }
    get linkUsedBody() {
        if (this._action === 'cancel') {
            return 'This appointment has already been canceled. Please contact us if you need to book a new one.';
        }
        if (this._action === 'reschedule') {
            return 'This appointment has already been rescheduled or canceled. Please contact us if you need further changes.';
        }
        return 'This scheduling link has already been used. Please contact us if you need to reschedule.';
    }

    get confirmationGreeting() {
        const fn = (this.firstName || '').trim();
        return fn ? `You're all set, ${fn}!` : `You're all set!`;
    }

    async _init() {
        try {
            const windowDays = this.isICMode ? this.openWindowDays : 0;
            const cfg = await getBookingConfig({
                openWindowDays: windowDays, bookingType: this._resolvedType,
                contactId: this._contactId, opportunityId: this._opportunityId,
                token: this._token,
                rescheduleToken: this._rescheduleToken || null
            });
            if (cfg.contactId && !this._contactId) this._contactId = cfg.contactId;
            if (cfg.opportunityId && !this._opportunityId) this._opportunityId = cfg.opportunityId;
            if (cfg.bookingType && !this._resolvedType) this._resolvedType = cfg.bookingType;
            if (cfg.isRescheduling) {
                this.isRescheduling = true;
                if (cfg.originalStartTime) {
                    try {
                        const dt = new Date(cfg.originalStartTime);
                        this.originalStartDisplay = dt.toLocaleString('en-US', {
                            timeZone: this.clientTimezone, weekday: 'long',
                            month: 'long', day: 'numeric', year: 'numeric',
                            hour: 'numeric', minute: '2-digit', hour12: true
                        });
                        // Compact form for the top banner: "Mon, April 27 · 3:00 pm IST"
                        const datePart = dt.toLocaleDateString('en-US', {
                            timeZone: this.clientTimezone, weekday: 'short',
                            month: 'long', day: 'numeric'
                        });
                        const timePart = dt.toLocaleTimeString('en-US', {
                            timeZone: this.clientTimezone, hour: 'numeric',
                            minute: '2-digit', hour12: true
                        }).toLowerCase();
                        let tzShort = '';
                        try {
                            const parts = new Intl.DateTimeFormat('en-US', {
                                timeZone: this.clientTimezone, timeZoneName: 'short'
                            }).formatToParts(dt);
                            const tzPart = parts.find(p => p.type === 'timeZoneName');
                            if (tzPart) tzShort = ' ' + tzPart.value;
                        } catch (_) { /* ignore */ }
                        this.originalStartCompact = `${datePart} · ${timePart}${tzShort}`;
                    } catch (_) {
                        this.originalStartDisplay = cfg.originalStartTime;
                        this.originalStartCompact = cfg.originalStartTime;
                    }
                }
                if (cfg.counselorName) {
                    this._counselorDisplayName = cfg.counselorName;
                    this._counselorFirstName = cfg.counselorName.trim().split(/\s+/)[0] || '';
                }
                if (cfg.counselorRole) this._counselorRole = cfg.counselorRole;
                if (cfg.rescheduleContactInfo) {
                    this.firstName    = cfg.rescheduleContactInfo.firstName    || '';
                    this.lastName     = cfg.rescheduleContactInfo.lastName     || '';
                    this.email        = cfg.rescheduleContactInfo.email        || '';
                    this.phone        = cfg.rescheduleContactInfo.phone        || '';
                    this.studentGrade = cfg.rescheduleContactInfo.studentGrade || '';
                    this.confirm1 = 'I confirm';
                    this.confirm2 = 'I confirm';
                    this.consentChecked = true;
                }
            }
            if (!cfg.success) {
                if (cfg.error === 'LINK_ALREADY_USED') {
                    this.isLinkAlreadyUsed = true;
                } else if (cfg.error === 'APPOINTMENT_PASSED') {
                    this.fatalErrorDetail = 'This appointment has already passed.';
                    this.hasFatalError = true;
                } else {
                    this.fatalErrorDetail = cfg.error || 'Configuration error';
                    this.hasFatalError = true;
                }
                this.isLoading = false;
                return;
            }
            this.config = cfg;
            const dates = cfg.availableDates || [];
            this.availableDateSet = new Set(dates);
            if (dates.length > 0) {
                const [y,m,d] = dates[dates.length-1].split('-');
                this.lastAvailableDate = new Date(+y, +m-1, +d);
            }

            // ── Auto-navigate to the month of the FIRST available date ──
            if (dates.length > 0) {
                const [fy, fm] = dates[0].split('-');
                this.calYear = +fy;
                this.calMonth = +fm - 1;
            } else {
                this.calYear = new Date().getFullYear();
                this.calMonth = new Date().getMonth();
            }

            this._renderCalendar();
            this.isLoading = false;
            this.isReady = true;
        } catch (err) {
            this.fatalErrorDetail = err?.body?.message || err?.message || 'Apex call failed';
            this.hasFatalError = true;
            this.isLoading = false;
        }
    }

    _getUrlParam(name) {
        try { return new URLSearchParams(window.location.search).get(name) || ''; }
        catch (_) { return ''; }
    }
    _toDateStr(d) {
        return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
    }

    _renderCalendar() {
        const days = [];
        const firstDay = new Date(this.calYear, this.calMonth, 1).getDay();
        const daysInMon = new Date(this.calYear, this.calMonth+1, 0).getDate();
        for (let i = 0; i < firstDay; i++) days.push({ key:'e'+i, isEmpty:true });
        for (let d = 1; d <= daysInMon; d++) {
            const dateStr = this._toDateStr(new Date(this.calYear, this.calMonth, d));
            const isAvail = this.availableDateSet.has(dateStr);
            const isSel = dateStr === this.selectedDate;
            if (!isAvail) {
                days.push({ key:dateStr, num:d, isDisabled:true, isEmpty:false });
            } else {
                days.push({ key:dateStr, num:d, dateStr, isEmpty:false, isDisabled:false,
                    cssClass: isSel ? 'cal-cell active selected' : 'cal-cell active' });
            }
        }
        this.calendarDays = days;
    }

    prevMonth() {
        if (this.calMonth === 0) { this.calMonth = 11; this.calYear--; }
        else this.calMonth--;
        this._renderCalendar();
    }
    nextMonth() {
        if (this.calMonth === 11) { this.calMonth = 0; this.calYear++; }
        else this.calMonth++;
        this._renderCalendar();
    }

    handleDateClick(event) {
        this.selectedDate = event.currentTarget.dataset.date;
        this.selectedStart = null;
        this.selectedEnd = null;
        this._renderCalendar();
        this._loadSlots();
    }

    async _loadSlots() {
        this.isSlotsLoading = true;
        this.timeSlots = [];
        try {
            const slots = await getAvailableSlots({
                dateStr: this.selectedDate, bookingType: this._resolvedType,
                contactId: this._contactId, opportunityId: this._opportunityId,
                rescheduleToken: this._rescheduleToken || null
            });
            this.timeSlots = (slots || []).map(s => ({
                startUtc: s.startUtc, endUtc: s.endUtc,
                displayTime: this._fmtTime(s.startUtc)
            }));
        } catch (err) { this.timeSlots = []; }
        finally { this.isSlotsLoading = false; }
    }

    _fmtTime(iso) {
        return new Date(iso).toLocaleTimeString('en-US',
            { timeZone: this.clientTimezone, hour:'numeric', minute:'2-digit', hour12:true });
    }

    handleSlotClick(event) {
        if (this.isSubmitting) return;
        this.selectedStart = event.currentTarget.dataset.start;
        this.selectedEnd = event.currentTarget.dataset.end;
        if (this.selectedStart && this.selectedEnd) {
            if (this.isICMode && !this.isRescheduling) {
                this.currentStep = 2;
                this.validationError = '';
            } else {
                this.handleSubmit();
            }
        }
    }

    handleInput(event) {
        const f = event.currentTarget.dataset.field;
        if (f) this[f] = event.currentTarget.value;
    }
    handleConsent(event) { this.consentChecked = event.currentTarget.checked; }
    handleEditTime() { this.currentStep = 1; this.validationError = ''; }
    handleBack() { this.currentStep = 1; this.validationError = ''; }

    // Grade button group → write the picklist value into studentGrade so the
    // existing Apex submit path is unchanged.
    handleGradeClick(event) {
        this.studentGrade = event.currentTarget.dataset.grade;
    }

    // Checkboxes set the same string ('I confirm') the legacy text inputs used,
    // so _validate() and the Apex payload stay identical.
    handleConfirm1(event) {
        this.confirm1 = event.currentTarget.checked ? 'I confirm' : '';
    }
    handleConfirm2(event) {
        this.confirm2 = event.currentTarget.checked ? 'I confirm' : '';
    }

    // Guest chip list handlers.
    handleNewGuestInput(event) {
        this.newGuestEmail = event.target.value;
        if (this.guestError) this.guestError = '';
    }
    handleGuestKeydown(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.handleAddGuest();
        }
    }
    handleAddGuest() {
        const raw = (this.newGuestEmail || '').trim().toLowerCase();
        if (!raw) return;
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(raw)) {
            this.guestError = 'Please enter a valid email address.';
            return;
        }
        if (this.guestEmailList.includes(raw)) {
            this.guestError = 'That guest is already on the list.';
            return;
        }
        if (this.guestEmailList.length >= 10) {
            this.guestError = 'You can invite up to 10 guests.';
            return;
        }
        this.guestEmailList = [...this.guestEmailList, raw];
        this.newGuestEmail = '';
        this.guestError = '';
    }
    handleRemoveGuest(event) {
        const target = event.currentTarget.dataset.email;
        this.guestEmailList = this.guestEmailList.filter(g => g !== target);
        this.guestError = '';
    }

    async handleSubmit() {
        if (this.isICMode && !this.isRescheduling) {
            this.submitAttempted = true;
            // Field-level errors render inline next to each input; the bottom
            // banner is reserved for booking-time errors (slot taken, save
            // failed, etc.) — so we clear it here on form-validation failures.
            const hasFieldErrors = !!(
                this.firstNameError || this.lastNameError || this.emailError
                || this.phoneError || this.studentGradeError
                || this.confirm1Error || this.confirm2Error || this.consentError
            );
            if (hasFieldErrors) { this.validationError = ''; return; }
        }
        this.validationError = '';
        this.isSubmitting = true;
        try {
            const result = await bookAppointment({
                startTimeISO: this.selectedStart, endTimeISO: this.selectedEnd,
                firstName: this.firstName.trim(), lastName: this.lastName.trim(),
                email: this.email.trim(), phone: this.phone.trim(),
                studentGrade: this.studentGrade, leadSource: this.leadSource,
                guestEmails: this.guestEmails.trim(), clientTimezone: this.clientTimezone,
                utmSource: this.utmSource, utmCampaign: this.utmCampaign, utmMedium: this.utmMedium,
                utmAd: this.utmAd, utmAdSet: this.utmAdSet,
                bookingType: this._resolvedType, contactId: this._contactId, opportunityId: this._opportunityId,
                rescheduleToken: this._rescheduleToken || null,
                notes: ''
            });
            if (result && result.success === 'true') {
                this.timeSlots = this.timeSlots.filter(s => s.startUtc !== this.selectedStart);
                this.currentStep = 3;
                if (this.redirectUrl) {
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => { window.location.href = this.redirectUrl; }, 8000);
                }
            } else if (result && result.error === 'LINK_ALREADY_USED') {
                this.isLinkAlreadyUsed = true;
                this.isReady = false;
            } else if (result && result.error === 'SLOT_UNAVAILABLE') {
                this.currentStep = 1;
                this.selectedStart = null; this.selectedEnd = null;
                this.validationError = 'This time slot is no longer available. Please select another time.';
                if (this.selectedDate) this._loadSlots();
            } else {
                this.validationError = (result && result.error) ? result.error : 'Booking could not be completed.';
            }
        } catch (error) {
            this.validationError = error?.body?.message || error?.message || 'An error occurred.';
        } finally { this.isSubmitting = false; }
    }
}