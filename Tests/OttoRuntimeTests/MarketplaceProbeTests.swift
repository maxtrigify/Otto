import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Native marketplace probes")
struct MarketplaceProbeTests {
  private func stub(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "apps-probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "provider")
    try
      ("#!/usr/bin/python3\nimport json,sys,os,time\ndef reply(value): print(json.dumps(value),flush=True)\n"
      + body)
      .write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return file
  }

  @Test func nativeAppsPaginationUsesAccountAndNoTurn() async throws {
    let file = try stub(
      #"""
      request=json.loads(input()); assert request['method']=='initialize'
      reply({'id':request['id'],'result':{}})
      assert json.loads(input())['method']=='initialized'
      request=json.loads(input()); assert request['method']=='account/read'
      reply({'id':request['id'],'result':{'account':{'type':'chatgpt'}}})
      request=json.loads(input()); assert request['method']=='app/list'; assert request['params']['forceRefetch']
      reply({'id':request['id'],'result':{'data':[{'id':os.environ['CODEX_HOME'],'name':'Gmail',
        'installUrl':'https://chatgpt.com/apps/gmail/id','isAccessible':False,'isEnabled':True}], 'nextCursor':'page2'}})
      request=json.loads(input()); assert request['params']['cursor']=='page2'
      reply({'id':request['id'],'result':{'data':[{'id':'notion','name':'Notion','isAccessible':True,'isEnabled':False}], 'nextCursor':None}})
      request=json.loads(input()); assert request['method']=='app/installed'
      reply({'id':request['id'],'result':{'apps':[{'id':os.environ['CODEX_HOME'],'enabled':True,'callable':True}]}})
      time.sleep(30)
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    for account in ["personal", "work"] {
      let apps = try #require(
        await LiveModelCatalog.discoverApps(
          executable: file.path, environment: ["CODEX_HOME": account]))
      #expect(apps.map(\.id) == [account, "notion"])
      // Directory accessibility false must not block initial setup.
      #expect(apps[0].installURL != nil)
      #expect(apps[0].isCallable == true)
      #expect(apps[1].isCallable == nil)
    }
  }

  @Test func noLoginAndAPIKeyNeverBecomeNativeAppCatalogues() async throws {
    #expect(
      await CodexAdapter().discoverMarketplaceApps(environment: ["OPENAI_API_KEY": "fixture"])
        == nil)
    for account in ["None", "{'type':'apiKey'}"] {
      let file = try stub(
        "r=json.loads(input()); reply({'id':r['id'],'result':{}})\ninput()\nr=json.loads(input()); reply({'id':r['id'],'result':{'account':\(account)}})\n"
      )
      defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
      #expect(await LiveModelCatalog.discoverApps(executable: file.path, environment: [:]) == nil)
    }
  }

  @Test func oldCLIUnsupportedInstalledEndpointStillReturnsDirectory() async throws {
    let file = try stub(
      #"""
      r=json.loads(input()); reply({'id':r['id'],'result':{}}); input()
      r=json.loads(input()); reply({'id':r['id'],'result':{'account':{'type':'chatgpt'}}})
      r=json.loads(input()); reply({'id':r['id'],'result':{'data':[{'id':'gmail','name':'Gmail'}], 'nextCursor':None}})
      r=json.loads(input()); reply({'id':r['id'],'error':{'code':-32601}})
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let apps = try #require(
      await LiveModelCatalog.discoverApps(executable: file.path, environment: [:]))
    #expect(apps.count == 1)
    #expect(apps[0].isCallable == nil)
  }

  @Test func fullDirectoryNotificationsDoNotExhaustModelProbeBudget() async throws {
    let file = try stub(
      #"""
      r=json.loads(input()); reply({'id':r['id'],'result':{}}); input()
      r=json.loads(input()); reply({'id':r['id'],'result':{'account':{'type':'chatgpt'}}})
      r=json.loads(input())
      reply({'method':'app/list/updated','params':{'data':[], 'metadata':'x'*(5*1024*1024)}})
      reply({'id':r['id'],'result':{'data':[{'id':'gmail','name':'Gmail'}], 'nextCursor':None}})
      r=json.loads(input()); reply({'id':r['id'],'result':{'apps':[]}})
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let apps = await LiveModelCatalog.discoverApps(executable: file.path, environment: [:])
    #expect(apps?.first?.id == "gmail")
    #expect(
      await CodexAdapter().discoverMarketplaceApps(environment: [
        "CODEX_HOME": "/fixture", "OPENAI_API_KEY": "fixture",
      ]) == nil)
  }

  @Test func publicDirectoryCanExceedThreeThousandApps() async throws {
    let file = try stub(
      #"""
      r=json.loads(input()); reply({'id':r['id'],'result':{}}); input()
      r=json.loads(input()); reply({'id':r['id'],'result':{'account':{'type':'chatgpt'}}})
      for page in range(7):
        r=json.loads(input()); assert r['method']=='app/list'
        assert r['params']['forceRefetch']==(page==0)
        rows=[{'id':str(page*500+i),'name':'Fixture app'} for i in range(500 if page<6 else 1)]
        reply({'id':r['id'],'result':{'data':rows,'nextCursor':str(page+1) if page<6 else None}})
      r=json.loads(input()); reply({'id':r['id'],'result':{'apps':[]}})
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let apps = await LiveModelCatalog.discoverApps(executable: file.path, environment: [:])
    #expect(apps?.count == 3001)
  }

  @Test func installRoutesRejectForeignHostsAndUnsafeSchemes() {
    for raw in [
      "http://chatgpt.com/apps/gmail/id", "https://chatgpt.com.evil.com/apps/id",
      "https://user:pass@chatgpt.com/apps/id", "https://chatgpt.com:443/apps/id", "file:///tmp/a",
      "https://chatgpt.com/logout",
    ] {
      #expect(ProviderMarketplaceApp.safeInstallURL(raw) == nil)
    }
    #expect(ProviderMarketplaceApp.safeInstallURL("https://chatgpt.com/apps/gmail/id") != nil)
    #expect(ProviderMarketplaceApp.safeInstallURL("https://chatgpt.com/plugins/github") != nil)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["OTTO_LIVE_MARKETPLACE_PROBE"] == "1"))
  func installedCodexNativeCatalogue() async throws {
    let apps = try #require(await CodexAdapter().discoverMarketplaceApps())
    #expect(!apps.isEmpty)
    print(
      "Live native Codex catalogue: \(apps.count) entries, \(apps.filter { $0.isCallable == true }.count) enabled; no inference turn started."
    )
  }
}
