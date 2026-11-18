-- Reverte sql/003_admin_auth.sql (painel admin.ducadu.com.br descontinuado neste repo).
-- Aplicar no Neon quando o app não for mais usado.

DROP TABLE IF EXISTS admin_user_roles;
DROP TABLE IF EXISTS admin_users;
DROP TYPE IF EXISTS admin_app_role;