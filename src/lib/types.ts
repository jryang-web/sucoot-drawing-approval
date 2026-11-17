export type Role = "EMPLOYEE" | "DEPT_MANAGER" | "DRAWING_MANAGER" | "DRAWING_STAFF" | "SYS_ADMIN";
export type Status =
  | "DRAFT" | "PENDING_DEPT_REVIEW" | "PENDING_DRAWING_REVIEW" | "PENDING_ISSUE"
  | "PENDING_RECEIPT" | "ISSUE_ABNORMAL" | "COMPLETED" | "RETURNED" | "REJECTED" | "CANCELLED";

export interface Me {
  id: string; employee_no: string; name: string; department_id: string; department_name: string;
  is_active: boolean; must_change_password: boolean; roles: Role[]; manager_departments: string[];
}
export interface Department { id: string; code: string; name: string; is_active: boolean }
export interface Employee {
  id: string; employee_no: string; name: string; department_id: string; is_active: boolean;
  must_change_password: boolean; auth_user_id: string | null;
}
export interface RequestRow {
  id: string; request_no: string; applicant_id: string; owner_id: string; department_id: string;
  status: Status; round: number; version: number; note: string | null; returned_level: number | null;
  submitted_at: string | null; issued_at: string | null; receipt_due_date: string | null;
  completed_at: string | null; created_at: string; updated_at: string;
  is_receipt_overdue: boolean; applicant_no: string; applicant_name: string; owner_no: string; owner_name: string;
  department_name: string; item_count: number; is_urgent: boolean | null; claimed_by: string | null;
}
export interface Item {
  id: string; request_id: string; line_no: number; drawing_no: string; drawing_name: string;
  revision: string | null; purpose: string; needed_date: string; is_urgent: boolean;
  urgency_reason: string | null; remark: string | null; downgrade_reason: string | null;
  receipt_status: "PENDING" | "RECEIVED" | "ABNORMAL";
}
/** 員工通訊錄（v_employee_directory）：一般員工可見的最小欄位 */
export interface DirectoryEntry { id: string; employee_no: string; name: string; department_id: string; is_active: boolean }
