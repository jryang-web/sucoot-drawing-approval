import OperationResults from "./components/OperationResults";
import type { ReactElement } from "react";
import { NavLink, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { useAuth } from "./lib/auth";
import type { Role } from "./lib/types";
import Login from "./pages/Login";
import ChangePassword from "./pages/ChangePassword";
import R8Admin from "./pages/admin/R8Admin";
import R8Home from "./pages/R8Home";
import R8Form from "./pages/R8Form";
import "./r8.css";

import RequestDetail from "./pages/request/RequestDetail";
import Queue from "./pages/Queue";
import Departments from "./pages/admin/Departments";
import Employees from "./pages/admin/Employees";
import Delegations from "./pages/admin/Delegations";
import Audit from "./pages/admin/Audit";
import Alerts from "./pages/admin/Alerts";
import ProductMaster from "./pages/admin/ProductMaster";
import VersionInfo from "./pages/VersionInfo";
import Footer from "./components/Footer";
import PwaBanner from "./components/PwaBanner";
import AppHeader from "./components/AppHeader";


export default function App() {
  const { session, me, loading, error, signOut, has } = useAuth();
  const { pathname } = useLocation();
  // 版本說明不需登入即可查看
  if (pathname === "/version") return <><PwaBanner /><AppHeader /><VersionInfo /><Footer /></>;
  if (loading) return <main><p className="muted">載入中…</p></main>;
  if (!session || !me) return <><PwaBanner /><AppHeader /><Login notice={error} /><Footer /></>;
  if (me.must_change_password) return <><PwaBanner /><AppHeader /><ChangePassword forced /><Footer /></>;

  // 依角色保護路由：沒有權限的網址一律導回「我的案件」（後端 RPC 另有權限檢查）
  const guard = (role: Role, el: ReactElement) => (has(role) ? el : <Navigate to="/my" replace />);
  const tab = (to: string, label: string) => <NavLink to={to} className={({ isActive }) => (isActive ? "tab active" : "tab")}>{label}</NavLink>;
  return (
    <>
      <PwaBanner />
      <AppHeader />
      <div className="root"><nav className="nav" aria-label="SUCOOT 主要功能">
        <div className="nav-tabs">
        {tab("/my", "工作首頁")}
        {tab("/new", "新增申請")}
        {tab(pathname.startsWith("/r/") ? pathname : "/detail", "案件明細與操作")}
        {has("SYS_ADMIN") && tab("/admin", "系統管理")}
        {tab("/password", "修改密碼")}
      </div></nav>
      <main className="content"><OperationResults key={session.user.id} user={session.user.id}/><div className="r8-identity">{me.employee_no}｜{me.name}｜{me.department_name}</div><div className="frame-shell"><div className="r8-screen">
        <Routes>
          <Route path="/detail" element={<div className="r8-card">請從工作首頁選擇一筆案件。</div>}/>
          <Route path="/admin" element={guard("SYS_ADMIN", <R8Admin />)}/>
          <Route path="/my" element={<R8Home />} />
          <Route path="/new" element={<R8Form />} />
          <Route path="/r/:id" element={<RequestDetail />} />
          <Route path="/r/:id/edit" element={<R8Form />} />
          <Route path="/queue/l1" element={guard("DEPT_MANAGER", <Queue key="l1" kind="l1" />)} />
          <Route path="/queue/l2" element={guard("DRAWING_MANAGER", <Queue key="l2" kind="l2" />)} />
          <Route path="/queue/issue" element={guard("DRAWING_STAFF", <Queue key="issue" kind="issue" />)} />
          <Route path="/admin/all" element={guard("SYS_ADMIN", <Queue all />)} />
          <Route path="/admin/alerts" element={guard("SYS_ADMIN", <Alerts />)} />
          <Route path="/admin/departments" element={guard("SYS_ADMIN", <Departments />)} />
          <Route path="/admin/employees" element={guard("SYS_ADMIN", <Employees />)} />
          <Route path="/admin/delegations" element={guard("SYS_ADMIN", <Delegations />)} />
          <Route path="/admin/audit" element={guard("SYS_ADMIN", <Audit />)} />
          <Route path="/admin/products" element={guard("SYS_ADMIN", <ProductMaster />)} />
          <Route path="/password" element={<ChangePassword />} />
          <Route path="*" element={<Navigate to="/my" replace />} />
        </Routes>
      </div></div><div className="bottom"><Footer /><button className="logout" onClick={signOut}>登出</button></div></main></div>
    </>
  );
}
