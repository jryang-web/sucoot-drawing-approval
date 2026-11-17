import type { ReactElement } from "react";
import { NavLink, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { useAuth } from "./lib/auth";
import type { Role } from "./lib/types";
import Login from "./pages/Login";
import ChangePassword from "./pages/ChangePassword";
import MyRequests from "./pages/MyRequests";
import RequestForm from "./pages/RequestForm";
import RequestDetail from "./pages/request/RequestDetail";
import Queue from "./pages/Queue";
import Departments from "./pages/admin/Departments";
import Employees from "./pages/admin/Employees";
import Delegations from "./pages/admin/Delegations";
import Audit from "./pages/admin/Audit";
import Alerts from "./pages/admin/Alerts";
import VersionInfo from "./pages/VersionInfo";
import Footer from "./components/Footer";
import PwaBanner from "./components/PwaBanner";
import { APP_NAME, APP_STAGE } from "./config";

export default function App() {
  const { session, me, loading, error, signOut, has } = useAuth();
  const { pathname } = useLocation();
  // 版本說明不需登入即可查看
  if (pathname === "/version") return <><PwaBanner /><VersionInfo /><Footer /></>;
  if (loading) return <main><p className="muted">載入中…</p></main>;
  if (!session || !me) return <><PwaBanner /><Login notice={error} /><Footer /></>;
  if (me.must_change_password) return <><PwaBanner /><ChangePassword forced /><Footer /></>;

  // 依角色保護路由：沒有權限的網址一律導回「我的案件」（後端 RPC 另有權限檢查）
  const guard = (role: Role, el: ReactElement) => (has(role) ? el : <Navigate to="/my" replace />);
  const tab = (to: string, label: string) => <NavLink to={to} className={({ isActive }) => (isActive ? "active" : "")}>{label}</NavLink>;
  return (
    <>
      <PwaBanner />
      <header className="top">
        <span className="brand">{APP_NAME}{APP_STAGE && <span className="stage">{APP_STAGE}</span>}</span>
        <span>{me.name}（{me.employee_no}）· {me.department_name}</span>
        <button onClick={signOut}>登出</button>
      </header>
      <nav className="tabs">
        {tab("/my", "我的案件")}
        {tab("/new", "新增申請")}
        {has("DEPT_MANAGER") && tab("/queue/l1", "第一層待審")}
        {has("DRAWING_MANAGER") && tab("/queue/l2", "第二層待審")}
        {has("DRAWING_STAFF") && tab("/queue/issue", "待發行／異常")}
        {has("SYS_ADMIN") && <>
          {tab("/admin/alerts", "警示")}
          {tab("/admin/all", "全部案件")}
          {tab("/admin/departments", "部門")}
          {tab("/admin/employees", "員工帳號")}
          {tab("/admin/delegations", "代理審核")}
          {tab("/admin/audit", "稽核紀錄")}
        </>}
        {tab("/password", "修改密碼")}
      </nav>
      <main>
        <Routes>
          <Route path="/my" element={<MyRequests />} />
          <Route path="/new" element={<RequestForm />} />
          <Route path="/r/:id" element={<RequestDetail />} />
          <Route path="/r/:id/edit" element={<RequestForm />} />
          <Route path="/queue/l1" element={guard("DEPT_MANAGER", <Queue key="l1" kind="l1" />)} />
          <Route path="/queue/l2" element={guard("DRAWING_MANAGER", <Queue key="l2" kind="l2" />)} />
          <Route path="/queue/issue" element={guard("DRAWING_STAFF", <Queue key="issue" kind="issue" />)} />
          <Route path="/admin/all" element={guard("SYS_ADMIN", <Queue all />)} />
          <Route path="/admin/alerts" element={guard("SYS_ADMIN", <Alerts />)} />
          <Route path="/admin/departments" element={guard("SYS_ADMIN", <Departments />)} />
          <Route path="/admin/employees" element={guard("SYS_ADMIN", <Employees />)} />
          <Route path="/admin/delegations" element={guard("SYS_ADMIN", <Delegations />)} />
          <Route path="/admin/audit" element={guard("SYS_ADMIN", <Audit />)} />
          <Route path="/password" element={<ChangePassword />} />
          <Route path="*" element={<Navigate to="/my" replace />} />
        </Routes>
      </main>
      <Footer />
    </>
  );
}
