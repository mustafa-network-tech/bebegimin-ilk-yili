import { forgotPasswordAction } from "@/app/actions/auth";
import { AuthForm } from "@/components/auth-form";

export default function ForgotPasswordPage() {
  return <><section className="auth-intro"><div className="brand"><span className="brand-mark">B</span><span><strong>Bebeğimin İlk Yılı</strong><small>Platform Yönetimi</small></span></div><div><p className="eyebrow">Hesap güvenliği</p><h1>Şifrenizi güvenle yenileyin.</h1><p>Sıfırlama bağlantısı yalnızca kayıtlı e-posta hesabınıza gönderilir.</p></div></section><section className="auth-panel"><div className="auth-card"><h1>Şifremi unuttum</h1><p>Yönetici hesabınızın e-posta adresini yazın.</p><AuthForm action={forgotPasswordAction} kind="forgot" /></div></section></>;
}
