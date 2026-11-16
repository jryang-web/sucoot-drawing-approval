import type { Role, Status } from "./types";

export const STATUS_LABEL: Record<Status, string> = {
  DRAFT: "草稿", PENDING_DEPT_REVIEW: "第一層待審", PENDING_DRAWING_REVIEW: "第二層待審",
  PENDING_ISSUE: "待發行", PENDING_RECEIPT: "待簽收", ISSUE_ABNORMAL: "發行異常",
  COMPLETED: "已完成", RETURNED: "已退回", REJECTED: "已拒絕", CANCELLED: "已取消",
};
export const ROLE_LABEL: Record<Role, string> = {
  EMPLOYEE: "一般員工", DEPT_MANAGER: "部門主管", DRAWING_MANAGER: "圖管主管",
  DRAWING_STAFF: "圖管人員", SYS_ADMIN: "系統管理員",
};
export const ALL_ROLES: Role[] = ["EMPLOYEE", "DEPT_MANAGER", "DRAWING_MANAGER", "DRAWING_STAFF", "SYS_ADMIN"];

export const fmt = (s: string | null | undefined) =>
  s ? new Date(s).toLocaleString("zh-TW", { timeZone: "Asia/Taipei", hour12: false }) : "—";
