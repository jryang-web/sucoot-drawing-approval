import { marked } from "marked";
import { Link } from "react-router-dom";
import readme from "../../README.md?raw";
import { APP_STAGE, APP_VERSION, BUILD_SHA, BUILD_TIME } from "../config";

// README.md 為版本庫內的受信任內容，於建置時打包進前端
const html = marked.parse(readme, { async: false }) as string;

export default function VersionInfo() {
  return (
    <main>
      <div className="card">
        <div className="row" style={{ justifyContent: "space-between" }}>
          <h1>版本說明</h1>
          <Link to="/my"><button>返回</button></Link>
        </div>
        <p className="muted">目前版本：v{APP_VERSION}{APP_STAGE && `（${APP_STAGE}）`} · build {BUILD_SHA} · {BUILD_TIME}</p>
        <article className="markdown" dangerouslySetInnerHTML={{ __html: html }} />
      </div>
    </main>
  );
}
