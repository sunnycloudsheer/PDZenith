import { LightningElement, api, track } from 'lwc';
import getBookingConfig    from '@salesforce/apex/GuestSchedulerController.getBookingConfigWithToken';
import getAvailableSlots   from '@salesforce/apex/GuestSchedulerController.getAvailableSlotsWithToken';
import bookAppointment     from '@salesforce/apex/GuestSchedulerController.bookAppointmentWithToken';

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
    @track currentStep = 1;
    @track isSlotsLoading = false;
    @track isSubmitting = false;

    // Step-1 level error (shown above the slot list for PD/FSS where there is no form step)
    @track bookingError = '';

    config = {};
    clientTimezone = 'America/Chicago';
    utmSource = ''; utmCampaign = ''; utmMedium = ''; leadSource = '';
    _contactId = '';
    _opportunityId = '';
    _token = '';
    _resolvedType = '';

    // Populated from getBookingConfig so the UI can show WHO the PD is before the user books
    @track assignedPdDisplay = '';

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
    @track guestEmails = '';
    @track consentChecked = false;
    @track validationError = '';

    connectedCallback() {
        try {
            this.clientTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/Chicago';
        } catch (_) {}
        this._resolvedType = this.bookingType || this._getUrlParam('type') || '';
        this._contactId = this._getUrlParam('contactId') || '';
        this._opportunityId = this._getUrlParam('opportunityId') || '';
        this._token = this._getUrlParam('token') || '';
        this.utmSource = this._getUrlParam('utm_source');
        this.utmCampaign = this._getUrlParam('utm_campaign');
        this.utmMedium = this._getUrlParam('utm_medium');
        this.leadSource = this._getUrlParam('lead_source') || 'Website';
        this._init();
    }

    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get step1NodeClass() { return this.currentStep >= 1 ? 'step-node active' : 'step-node'; }
    get step2NodeClass() { return this.currentStep >= 2 ? 'step-node active' : 'step-node'; }
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
    get isPDMode()  { return this._resolvedType === 'PD'; }
    get isFSSMode() { return this._resolvedType === 'FSS'; }
    get headerLabel() {
        if (this._resolvedType === 'PD') return 'Program Director Meeting with Zenith Prep Academy';
        if (this._resolvedType === 'FSS') return 'FSS Onboarding Meeting with Zenith Prep Academy';
        return 'Initial Consultation with Zenith Prep Academy';
    }
    get showAssignedPdBanner() {
        return this.isPDMode && !!this.assignedPdDisplay;
    }

    async _init() {
        try {
            const windowDays = this.isICMode ? this.openWindowDays : 0;
            const cfg = await getBookingConfig({
                openWindowDays: windowDays, bookingType: this._resolvedType,
                contactId: this._contactId, opportunityId: this._opportunityId,
                token: this._token
            });
            if (!cfg.success) {
                this.fatalErrorDetail = cfg.error || 'Configuration error';
                this.hasFatalError = true;
                this.isLoading = false;
                return;
            }
            this.config = cfg;

            // If Apex pre-assigned (or already had) a sticky PD, show the name up-front
            if (cfg.isSticky && cfg.stickyUserId) {
                // We don't have the name back from the server in this payload; the banner just
                // confirms "your PD is assigned" so the user knows who they'll meet with.
                this.assignedPdDisplay = 'Your dedicated Program Director';
            }

            const dates = cfg.availableDates || [];
            this.availableDateSet = new Set(dates);
            if (dates.length > 0) {
                const [y,m,d] = dates[dates.length-1].split('-');
                this.lastAvailableDate = new Date(+y, +m-1, +d);
            }

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
        this.bookingError = '';
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
                token: this._token
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
        // Ignore clicks while a previous booking is still in flight — prevents the
        // "click does nothing / ends up double-booking" feel.
        if (this.isSubmitting) return;

        this.selectedStart = event.currentTarget.dataset.start;
        this.selectedEnd   = event.currentTarget.dataset.end;
        this.bookingError  = '';

        if (!this.selectedStart || !this.selectedEnd) return;

        if (this.isICMode) {
            // IC keeps the two-step form flow
            this.currentStep = 2;
            this.validationError = '';
        } else {
            // PD / FSS book immediately — the user was identified via contactId/opportunityId
            // in the URL, so no additional form is needed.
            this.handleSubmit();
        }
    }

    handleInput(event) {
        const f = event.currentTarget.dataset.field;
        if (f) this[f] = event.currentTarget.value;
    }
    handleConsent(event) { this.consentChecked = event.currentTarget.checked; }
    handleEditTime() { this.currentStep = 1; this.validationError = ''; }
    handleBack() { this.currentStep = 1; this.validationError = ''; }

    _validate() {
        if (!this.firstName.trim()) return 'First name is required.';
        if (!this.lastName.trim()) return 'Last name is required.';
        if (!this.email.trim()) return 'Email is required.';
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.email.trim()))
            return 'Please enter a valid email address.';
        if (this.phone.replace(/\D/g,'').length < 10)
            return 'Phone number must be at least 10 digits.';
        if (!this.studentGrade) return 'Please select a student grade.';
        if (this.confirm1.trim().toLowerCase() !== 'i confirm')
            return "First confirmation must say exactly: I confirm";
        if (this.confirm2.trim().toLowerCase() !== 'i confirm')
            return "Second confirmation must say exactly: I confirm";
        if (!this.consentChecked)
            return 'You must agree to receive communications.';
        return '';
    }

    async handleSubmit() {
        if (this.isICMode) {
            const err = this._validate();
            if (err) { this.validationError = err; return; }
        }
        this.validationError = '';
        this.bookingError    = '';
        this.isSubmitting = true;
        try {
            const result = await bookAppointment({
                startTimeISO: this.selectedStart, endTimeISO: this.selectedEnd,
                firstName: this.firstName.trim(), lastName: this.lastName.trim(),
                email: this.email.trim(), phone: this.phone.trim(),
                studentGrade: this.studentGrade, leadSource: this.leadSource,
                guestEmails: this.guestEmails.trim(), clientTimezone: this.clientTimezone,
                utmSource: this.utmSource, utmCampaign: this.utmCampaign, utmMedium: this.utmMedium,
                bookingType: this._resolvedType, contactId: this._contactId, opportunityId: this._opportunityId,
                token: this._token
            });
            if (result && result.success === 'true') {
                this.timeSlots = this.timeSlots.filter(s => s.startUtc !== this.selectedStart);
                this.currentStep = 3;
                if (this.redirectUrl) {
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => { window.location.href = this.redirectUrl; }, 3000);
                }
            } else if (result && result.error === 'SLOT_UNAVAILABLE') {
                this.currentStep = 1;
                this.selectedStart = null; this.selectedEnd = null;
                const msg = 'This time slot is no longer available. Please select another time.';
                this.validationError = msg;
                this.bookingError    = msg;
                if (this.selectedDate) this._loadSlots();
            } else {
                const msg = (result && result.error) ? result.error : 'Booking could not be completed.';
                this.validationError = msg;
                this.bookingError    = msg;
            }
        } catch (error) {
            const msg = error?.body?.message || error?.message || 'An error occurred.';
            this.validationError = msg;
            this.bookingError    = msg;
        } finally { this.isSubmitting = false; }
    }
}