import Foundation

/// The page scripts website accounts run: the Mac's WebKit driver and Otto Desktop's Chromium
/// driver share them, so private sign-in and bot actions are checked identically everywhere.
/// Each is a function body evaluated with named arguments in an isolated script world.
enum WebsiteAccountScripts {
  static let sensitiveFields =
    "return [...document.querySelectorAll('input')].some(e => (e.type === 'password' || /(?:one-time-code|current-password|new-password)/.test(e.autocomplete)) && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');"

  /// Arguments: revision, human.
  static let inspect = """
    const visible = e => e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
    const selector = human ? 'input:not([type=hidden]),textarea,button,select' : 'input:not([type=hidden]),textarea,button,a[href],select';
    const elements = [...document.querySelectorAll(selector)].filter(visible).slice(0,200);
    const fingerprint = e => [e.tagName,e.type,e.name,e.getAttribute('href'),e.form?.action,e.getAttribute('formaction'),e.innerText,e.getAttribute('aria-label')].join('\\u001f');
    globalThis.__ottoPrivate = { revision, elements, fingerprint, marks:elements.map(fingerprint) };
    const entries = elements.map((e,i) => ({id:String(i), label:(e.labels?.[0]?.innerText || e.getAttribute('aria-label') || e.innerText || e.placeholder || e.type || e.tagName).slice(0,160), purpose:e.type==='password' && e.autocomplete!=='new-password' ? 'password' : e.autocomplete==='one-time-code' ? 'otp' : null, kind:e.matches('input,textarea') ? (e.type === 'password' || /(?:one-time-code|current-password|new-password)/.test(e.autocomplete) ? 'secret' : 'field') : 'button'}));
    return {elements:entries, text:human ? '' : (document.body?.innerText || '').slice(0,20000)};
    """

  /// The login form's username and password fields; ends with `signature` defined.
  static let credentialFields = """
    const visible=e=>e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden';
    const passwords=[...document.querySelectorAll('input[type=password]')].filter(visible);
    if(passwords.length!==1 || passwords[0].autocomplete==='new-password')return null;
    const p=passwords[0], f=p.form;
    if(!f || new URL(f.action).origin!==location.origin)return null;
    const usernames=[...f.querySelectorAll('input')].filter(e=>visible(e)&&['text','email'].includes(e.type));
    if(usernames.length!==1)return null;
    const u=usernames[0];if(!(u.name||u.id)||!(p.name||p.id))return null;
    const signature=JSON.stringify([location.origin,f.action,u.name,u.id,u.type,p.name,p.id]);
    """

  /// After credentialFields. Arguments: expected, username, password.
  static let fillSuffix = """
    if(signature!==expected)return false;
    const buttons=[...f.querySelectorAll('button[type=submit],input[type=submit],button:not([type])')].filter(e=>visible(e)&&!e.disabled);
    if(buttons.length!==1)return false;
    const set=(e,value)=>{Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,value);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));};
    set(u,username);set(p,password);
    if(!p.isConnected||!u.isConnected||!buttons[0].isConnected||new URL(f.action).origin!==location.origin)return false;
    buttons[0].click();return true;
    """

  /// After credentialFields. Arguments: revision, fields.
  static let candidateSuffix = """
    const s=globalThis.__ottoPrivate;if(!s||s.revision!==revision)return null;
    const ui=s.elements.indexOf(u),pi=s.elements.indexOf(p);
    if(ui<0||pi<0||s.fingerprint(u)!==s.marks[ui]||s.fingerprint(p)!==s.marks[pi])return null;
    if(typeof fields[String(pi)]!=='string'||!fields[String(pi)])return null;
    return {signature,username:fields[String(ui)]??u.value,password:fields[String(pi)]};
    """

  /// Arguments: revision, id.
  static let targetLabel = """
    const s=globalThis.__ottoPrivate, e=s?.elements[Number(id)];
    if(!s || s.revision!==revision || !e?.isConnected || !e.getClientRects().length || getComputedStyle(e).visibility==='hidden' || e.disabled || s.fingerprint(e)!==s.marks[Number(id)]) return null;
    return (e.labels?.[0]?.innerText || e.getAttribute('aria-label') || e.innerText || e.type || e.tagName).slice(0,160);
    """

  /// Arguments: revision, id, kind, value, human, fields.
  static let act = """
    const s=globalThis.__ottoPrivate; if(!s || s.revision!==revision) return false;
    globalThis.__ottoPrivate=null;
    const e=s.elements[Number(id)]; if(!e?.isConnected || !e.getClientRects().length || getComputedStyle(e).visibility==='hidden' || e.disabled || s.fingerprint(e)!==s.marks[Number(id)]) return false;
    if(!human && (e.type==='password' || /(?:one-time-code|current-password|new-password)/.test(e.autocomplete))) return false;
    const entries=Object.entries(fields);
    const validField = (key) => { const f=s.elements[Number(key)]; return /^\\d+$/.test(key) && f?.isConnected && f.matches('input,textarea') && f.getClientRects().length && getComputedStyle(f).visibility!=='hidden' && !f.disabled && s.fingerprint(f)===s.marks[Number(key)]; };
    if(entries.some(([key])=>!validField(key))) return false;
    for(const [key,text] of entries) {
      const f=s.elements[Number(key)]; if(!validField(key)) return false;
      const proto=f.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto,'value').set.call(f,text);
      f.dispatchEvent(new Event('input',{bubbles:true})); f.dispatchEvent(new Event('change',{bubbles:true}));
    }
    if(!e.isConnected || e.disabled || s.fingerprint(e)!==s.marks[Number(id)]) return false;
    if(kind==='click') { e.click(); return true; }
    if(!e.matches('input,textarea')) return false;
    const prototype=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype,'value').set.call(e,value);
    e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true})); return true;
    """
}
