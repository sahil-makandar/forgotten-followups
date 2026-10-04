-- 05 Mount the payer's Secure Data Share in the hospital account (run after sql/payer/01 and 02).
CREATE DATABASE IF NOT EXISTS PAYER_SHARE FROM SHARE WUDPKQN.AK85293.FFU_SHARE;
-- Proof: expect only partner_account = AZ66410 rows, and masked SSN.
SELECT partner_account, COUNT(*) AS n, MAX(member_ssn_last4) AS ssn
FROM PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS GROUP BY 1;
