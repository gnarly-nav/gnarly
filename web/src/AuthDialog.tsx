import { useEffect, useRef, useState } from 'react';
import { ArrowRight, X } from 'lucide-react';
import { login, logout, signInConfigured, signInWithGoogle, takeAuthError } from './cloud';

export default function AuthDialog({connected,email,onClose,onBeforeLogout}:{connected:boolean;email:string;onClose:()=>void;onBeforeLogout:()=>boolean}) {
  const dialog=useRef<HTMLDialogElement>(null);
  const [address,setAddress]=useState(''),[password,setPassword]=useState(''),[error,setError]=useState(''),[busy,setBusy]=useState(false),[emailMode,setEmailMode]=useState(false);
  useEffect(()=>{dialog.current?.showModal();const message=takeAuthError();if(message)setError(message);return()=>dialog.current?.close()},[]);
  async function google(){
    if(busy)return;
    setBusy(true);setError('');
    try{await signInWithGoogle()}
    catch(failure){setError(failure instanceof Error?failure.message:String(failure));setBusy(false)}
  }
  async function submit(){
    if(busy)return;
    if(connected&&!onBeforeLogout())return;
    setBusy(true);setError('');
    try{
      if(connected){if(!logout()){setBusy(false);onClose()}}
      else{await login(address,password);setPassword('');setBusy(false);onClose()}
    }
    catch(failure){setError(failure instanceof Error?failure.message:String(failure));setBusy(false)}
  }
  return <dialog ref={dialog} className="modal auth-dialog" aria-labelledby="auth-title" onCancel={event=>{event.preventDefault();if(!busy)onClose()}}>
    <form onSubmit={event=>{event.preventDefault();void submit()}}>
      <button type="button" className="close" disabled={busy} onClick={onClose} aria-label="Close account dialog"><X size={19}/></button>
      <span className="route-eyebrow">ACCOUNT</span><h2 id="auth-title">{connected?'Signed in':'Sign in'}</h2>
      <p>{connected?`Signed in as ${email}. Only the authorized editor can change maps.`:'Anyone can view maps. Sign in with Google only if this browser should edit them.'}</p>
      {!signInConfigured?<div className="notice">Cognito is not configured.</div>:connected?<>
        {error&&<div className="error" role="alert">{error}</div>}
        <button className="primary" type="submit" disabled={busy}>{busy?'Please wait…':'Sign out'}<ArrowRight size={17}/></button>
      </>:<>
        <button className="primary" type="button" disabled={busy} onClick={()=>void google()}>{busy?'Please wait…':'Sign in with Google'}<ArrowRight size={17}/></button>
        {!emailMode?<button type="button" className="secondary" disabled={busy} onClick={()=>setEmailMode(true)}>Use email and password</button>:<>
          <label>Email<input autoFocus required type="email" autoComplete="username" value={address} disabled={busy} onChange={e=>setAddress(e.target.value)}/></label>
          <label>Password<input required type="password" autoComplete="current-password" value={password} disabled={busy} onChange={e=>setPassword(e.target.value)}/></label>
          <button className="secondary" type="submit" disabled={busy}>{busy?'Please wait…':'Sign in'}<ArrowRight size={17}/></button>
        </>}
        {error&&<div className="error" role="alert">{error}</div>}
      </>}
    </form>
  </dialog>;
}
