import { Link } from "react-router-dom";
import InstallHint from "./InstallHint";
import { APP_NAME, APP_VERSION, BUILD_SHA, BUILD_TIME, RELEASE_LABEL } from "../config";

export default function Footer() {
  return (
    <footer className="foot">
      <span>{APP_NAME} {RELEASE_LABEL}</span>
      <span>v{APP_VERSION}（build {BUILD_SHA} · {BUILD_TIME}）</span>
      <Link to="/version">版本說明</Link>
      <InstallHint />
    </footer>
  );
}
