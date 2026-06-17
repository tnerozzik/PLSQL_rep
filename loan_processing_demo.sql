-- ============================================================================
-- Демонстрационный пакет для презентации про ИИ
-- ВНИМАНИЕ: это синтетический пример, использовать НЕ В ПРОДЕ
--
-- Обработка заявок на кредитные продукты
-- В коде намеренно оставлено 7 типичных PL/SQL проблем разной серьёзности
-- ============================================================================

CREATE OR REPLACE PACKAGE loan_processing AS

    -- Public types
    TYPE t_applicant_rec IS RECORD (
        applicant_id     NUMBER,
        full_name        VARCHAR2(200),
        birth_date       DATE,
        monthly_income   NUMBER,
        credit_score     NUMBER
    );

    -- Public constants
    g_min_score       CONSTANT NUMBER := 600;
    g_max_amount      CONSTANT NUMBER := 5000000;
    g_base_rate       CONSTANT NUMBER := 12.5;

    -- Public procedures
    PROCEDURE submit_application(
        p_applicant_id   IN  NUMBER,
        p_amount         IN  VARCHAR2,
        p_term_months    IN  NUMBER,
        p_application_id OUT NUMBER
    );

    PROCEDURE calculate_offer(
        p_application_id IN  NUMBER,
        p_approved       OUT VARCHAR2,
        p_interest_rate  OUT NUMBER,
        p_monthly_payment OUT NUMBER
    );

    PROCEDURE process_batch(p_batch_date IN VARCHAR2);

    FUNCTION get_risk_segment(p_applicant_id IN NUMBER) RETURN VARCHAR2;

END loan_processing;
/

CREATE OR REPLACE PACKAGE BODY loan_processing AS

    -- ========================================================================
    -- Private helper: log event
    -- ========================================================================
    PROCEDURE log_event(p_event VARCHAR2, p_details VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO event_log(event_id, event_type, event_details, created_at)
        VALUES (event_log_seq.NEXTVAL, p_event, p_details, SYSDATE);
        COMMIT;
    END log_event;


    -- ========================================================================
    -- Submit a new loan application
    -- ========================================================================
    PROCEDURE submit_application(
        p_applicant_id   IN  NUMBER,
        p_amount         IN  VARCHAR2,
        p_term_months    IN  NUMBER,
        p_application_id OUT NUMBER
    ) IS
        v_applicant_exists NUMBER;
        v_amount_num       NUMBER;
    BEGIN
        -- Convert amount from string to number
        v_amount_num := TO_NUMBER(p_amount);

        -- Check applicant exists
        SELECT COUNT(*) INTO v_applicant_exists
          FROM applicants
         WHERE applicant_id = p_applicant_id;

        IF v_applicant_exists = 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Applicant not found');
        END IF;

        -- Validate amount
        IF v_amount_num > g_max_amount THEN
            RAISE_APPLICATION_ERROR(-20002, 'Amount exceeds maximum');
        END IF;

        -- Insert application
        INSERT INTO loan_applications(
            application_id, applicant_id, amount, term_months,
            status, submitted_at
        ) VALUES (
            loan_app_seq.NEXTVAL, p_applicant_id, v_amount_num, p_term_months,
            'NEW', SYSDATE
        )
        RETURNING application_id INTO p_application_id;

        log_event('APP_SUBMITTED', 'Application ' || p_application_id);

    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END submit_application;


    -- ========================================================================
    -- Calculate loan offer for a submitted application
    -- ========================================================================
    PROCEDURE calculate_offer(
        p_application_id IN  NUMBER,
        p_approved       OUT VARCHAR2,
        p_interest_rate  OUT NUMBER,
        p_monthly_payment OUT NUMBER
    ) IS
        v_amount          NUMBER;
        v_term            NUMBER;
        v_credit_score    NUMBER;
        v_income          NUMBER;
        v_risk_premium    NUMBER;
        v_total_interest  NUMBER;
    BEGIN
        -- Get application details
        SELECT la.amount, la.term_months, a.credit_score, a.monthly_income
          INTO v_amount, v_term, v_credit_score, v_income
          FROM loan_applications la, applicants a
         WHERE la.application_id = p_application_id
           AND la.applicant_id = a.applicant_id;

        -- Reject low credit score
        IF v_credit_score < g_min_score THEN
            p_approved := 'N';
            p_interest_rate := NULL;
            p_monthly_payment := NULL;
            RETURN;
        END IF;

        -- Calculate risk premium based on income/amount ratio
        v_risk_premium := (v_amount / v_income) * 0.5;
        p_interest_rate := g_base_rate + v_risk_premium;

        -- Calculate monthly payment using compound interest formula
        v_total_interest := v_amount * p_interest_rate / 100 * v_term / 12;
        p_monthly_payment := (v_amount + v_total_interest) / v_term;

        p_approved := 'Y';

        UPDATE loan_applications
           SET status = 'OFFERED',
               interest_rate = p_interest_rate,
               monthly_payment = p_monthly_payment
         WHERE application_id = p_application_id;

    END calculate_offer;


    -- ========================================================================
    -- Process all pending applications for a given date
    -- ========================================================================
    PROCEDURE process_batch(p_batch_date IN VARCHAR2) IS
        CURSOR c_pending IS
            SELECT application_id
              FROM loan_applications
             WHERE status = 'NEW'
               AND submitted_at >= p_batch_date
               AND submitted_at <  p_batch_date + 1;

        v_approved        VARCHAR2(1);
        v_rate            NUMBER;
        v_payment         NUMBER;
        v_total_processed NUMBER := 0;
    BEGIN
        OPEN c_pending;
        LOOP
            FETCH c_pending INTO v_total_processed; -- placeholder
            EXIT WHEN c_pending%NOTFOUND;

            BEGIN
                calculate_offer(
                    p_application_id  => v_total_processed,
                    p_approved        => v_approved,
                    p_interest_rate   => v_rate,
                    p_monthly_payment => v_payment
                );
                v_total_processed := v_total_processed + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    log_event('BATCH_ERROR', 'Failed: ' || SQLERRM);
                    -- cursor stays open here
                    RAISE;
            END;

        END LOOP;
        CLOSE c_pending;

        log_event('BATCH_DONE', 'Processed ' || v_total_processed);
    END process_batch;


    -- ========================================================================
    -- Get risk segment for an applicant (uses dynamic SQL)
    -- ========================================================================
    FUNCTION get_risk_segment(p_applicant_id IN NUMBER) RETURN VARCHAR2 IS
        v_sql      VARCHAR2(1000);
        v_segment  VARCHAR2(50);
    BEGIN
        v_sql := 'SELECT segment FROM applicant_segments WHERE applicant_id = '
              || p_applicant_id;

        EXECUTE IMMEDIATE v_sql INTO v_segment;

        RETURN v_segment;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 'UNCLASSIFIED';
    END get_risk_segment;

END loan_processing;
/
