import { NavLink, Navigate, Route, Routes } from "react-router-dom";
import { useAuth } from "./lib/auth";
import Login from "./pages/Login";
import ChangePassword from "./pages/ChangePassword";
import MyRequests from "./pages/MyRequests";
import RequestForm from "./pages/RequestForm";
import RequestDetail from "./pages/RequestDetail";
import Queue from "./pages/Queue";
import Departments from "./pages/admin/Departments";
import Employees from "./pages/admin/Employees";
import Delegations from "./pages/admin/Delegations";
import Audit from "./pages/admin/Audit";
import Alerts from "./pages/admin/Alerts";

export default function App() {
  const { session, me, loading, error, signOut, has } = useAuth();
  if (loading) return <main><p className="muted">載入中…</p></main>;
  if (!session || !me) return <Login notice={error} />;
  if (me.must_change_password) return <ChangePassword forced />;

  const tab = (to: string, label: string) => <NavLink to={to} className={({ isActive }) => (isActive ? "active" : "")}>{label}</NavLink>;
  return (
    <>
      <header className="top">
        <span className="brand">SUCOOT 圖面申請</span>
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
          <Route path="/queue/:kind" element={<Queue />} />
          <Route path="/admin/all" element={<Queue all />} />
          <Route path="/admin/alerts" element={<Alerts />} />
          <Route path="/admin/departments" element={<Departments />} />
          <Route path="/admin/employees" element={<Employees />} />
          <Route path="/admin/delegations" element={<Delegations />} />
          <Route path="/admin/audit" element={<Audit />} />
          <Route path="/password" element={<ChangePassword />} />
          <Route path="*" element={<Navigate to="/my" replace />} />
        </Routes>
      </main>
    </>
  );
}
