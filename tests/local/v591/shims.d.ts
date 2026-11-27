// 測試用套件型別（只描述本測試用到的部分）
declare module "http_ece" {
  const ece: { decrypt(buf: Buffer, opts: { version: string; privateKey: unknown; authSecret: string }): Buffer };
  export default ece;
}
declare module "pg" {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- 測試替身：查詢結果欄位依 SQL 而定
  interface QueryResult { rows: any[] }
  interface Client { query(sql: string, params?: unknown[]): Promise<QueryResult>; release(): void }
  class Pool { constructor(o: object); connect(): Promise<Client>; query(sql: string, params?: unknown[]): Promise<QueryResult>; end(): Promise<void> }
  const pg: { Pool: typeof Pool };
  export default pg;
}
