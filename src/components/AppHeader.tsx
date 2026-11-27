import markUrl from "../assets/brand/sucoot-mark.png";
import wordmarkUrl from "../assets/brand/sucoot-wordmark.png";
import "./AppHeader.css";

/**
 * 全站共用頁首：SUCOOT 公司 LOGO（原始圖檔裁切，保留原色與比例）＋系統名稱。
 * 登入頁、強制改密碼、版本說明與登入後主畫面都使用同一個元件。
 */
export default function AppHeader() {
  return (
    <header className="app-header">
      <div className="app-header__inner">
        <span className="app-header__logo" role="img" aria-label="SUCOOT">
          <img className="app-header__mark" src={markUrl} alt="" width={184} height={192} decoding="async" />
          <img className="app-header__wordmark" src={wordmarkUrl} alt="" width={519} height={88} decoding="async" />
        </span>
        <span className="app-header__divider" aria-hidden="true" />
        <span className="app-header__system">
          圖面申請與審核<small>V5.9.1</small>
        </span>
      </div>
    </header>
  );
}
