import { updatePasswordAction } from "@/app/actions/auth";
import { AuthForm } from "@/components/auth-form";

export default function ResetPasswordPage() {
  return <><section className="auth-intro"><div className="brand"><span className="brand-mark">B</span><span><strong>Bebeğimin İlk Yılı</strong><small>Platform Yönetimi</small></span></div><div><p className="eyebrow">Yeni şifre</p><h1>Hesabınızı yeniden güvenceye alın.</h1><p>En az 8 karakterlik, başka yerde kullanmadığınız bir şifre seçin.</p></div></section><section className="auth-panel"><div className="auth-card"><h1>Şifreyi yenile</h1><AuthForm action={updatePasswordAction} kind="reset" /></div></section></>;
}
