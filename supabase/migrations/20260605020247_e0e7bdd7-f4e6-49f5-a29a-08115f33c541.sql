CREATE OR REPLACE FUNCTION public.spend_credits_auto(
  p_user_id uuid,
  p_workspace_id uuid,
  p_amount numeric,
  p_action_type text,
  p_description text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member record;
  v_ws record;
  v_new_credits numeric;
  v_personal jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'auth_required');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_amount');
  END IF;

  IF p_workspace_id IS NOT NULL THEN
    SELECT * INTO v_member FROM public.workspace_members
      WHERE workspace_id = p_workspace_id AND user_id = p_user_id FOR UPDATE;

    IF v_member.id IS NOT NULL THEN
      IF date_trunc('month', now()) > date_trunc('month', v_member.monthly_period_start) THEN
        UPDATE public.workspace_members
          SET monthly_used = 0, monthly_period_start = date_trunc('month', now())
          WHERE id = v_member.id;
        v_member.monthly_used := 0;
      END IF;

      IF v_member.monthly_limit IS NOT NULL
         AND (v_member.monthly_used + p_amount) > v_member.monthly_limit THEN
        RETURN jsonb_build_object('success', false, 'error', 'monthly_limit_exceeded',
          'limit', v_member.monthly_limit, 'used', v_member.monthly_used);
      END IF;

      SELECT * INTO v_ws FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
      IF v_ws.credits < p_amount THEN
        RETURN jsonb_build_object('success', false, 'error', 'insufficient_workspace_credits',
          'credits', v_ws.credits);
      END IF;

      v_new_credits := v_ws.credits - p_amount;
      UPDATE public.workspaces SET credits = v_new_credits, updated_at = now()
        WHERE id = p_workspace_id;
      UPDATE public.workspace_members SET monthly_used = monthly_used + p_amount
        WHERE id = v_member.id;
      INSERT INTO public.workspace_usage (workspace_id, user_id, amount, action_type, description)
        VALUES (p_workspace_id, p_user_id, p_amount, p_action_type, p_description);

      RETURN jsonb_build_object('success', true, 'credits', v_new_credits,
        'monthly_used', v_member.monthly_used + p_amount,
        'source', 'workspace');
    END IF;
  END IF;

  v_personal := public.deduct_credits(p_user_id, p_amount, p_action_type, p_description);
  RETURN COALESCE(v_personal, jsonb_build_object('success', false, 'error', 'unknown'))
         || jsonb_build_object('source', 'personal');
END
$$;

GRANT EXECUTE ON FUNCTION public.spend_credits_auto(uuid, uuid, numeric, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.workspace_create_invite(
  p_workspace_id uuid,
  p_email text,
  p_role workspace_role DEFAULT 'member'::workspace_role
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_token text;
  v_id uuid;
  v_email text := lower(trim(p_email));
  v_target uuid;
  v_ws_name text;
  v_inviter text;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'auth_required');
  END IF;
  IF NOT public.is_workspace_admin(p_workspace_id, v_user) THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden');
  END IF;
  IF v_email IS NULL OR v_email = '' OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_email');
  END IF;

  INSERT INTO public.workspace_invites (workspace_id, invited_by, invite_email, role)
  VALUES (p_workspace_id, v_user, v_email, p_role)
  RETURNING id, invite_token INTO v_id, v_token;

  SELECT id INTO v_target FROM auth.users WHERE lower(email) = v_email LIMIT 1;

  IF v_target IS NOT NULL THEN
    SELECT name INTO v_ws_name FROM public.workspaces WHERE id = p_workspace_id;
    SELECT COALESCE(display_name, 'A teammate') INTO v_inviter FROM public.profiles WHERE id = v_user;

    PERFORM public.create_notification(
      v_target,
      'workspace_invite',
      'دعوة لمساحة عمل: ' || COALESCE(v_ws_name, 'Workspace'),
      COALESCE(v_inviter, 'مستخدم') || ' دعاك للانضمام إلى مساحة العمل.',
      jsonb_build_object(
        'workspace_id', p_workspace_id,
        'workspace_name', v_ws_name,
        'invite_id', v_id,
        'invite_token', v_token,
        'role', p_role,
        'link', '/auth/accept-workspace-invite?token=' || v_token
      )
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'invite_id', v_id, 'token', v_token,
    'notified_in_app', v_target IS NOT NULL);
END
$$;