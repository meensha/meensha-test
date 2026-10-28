-- Kiosk Notes v2: rich-text notes per Pop-up Event (Apple Notes style).
--
-- body_html holds the note's sanitised rich text. The plain `note` column is
-- still written for every note (first line = title in the kiosk list), so
-- admin.html's "Analyze & Submit" keeps reading `note` as plain text.
-- popup_notes_add and popup_notes_list are unchanged.

ALTER TABLE popup_notes
  ADD COLUMN IF NOT EXISTS body_html text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- All notes for one event, most recently touched first. Old plain-text notes
-- have body_html NULL; the kiosk renders them as plain text.
CREATE OR REPLACE FUNCTION public.popup_notes_full(p_popup_id uuid)
 RETURNS TABLE(id uuid, note text, body_html text, written_by_name text, created_at timestamptz, updated_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  RETURN QUERY
    SELECT n.id, n.note, n.body_html, n.written_by_name, n.created_at, n.updated_at
    FROM popup_notes n
    WHERE n.popup_id = p_popup_id
    ORDER BY coalesce(n.updated_at, n.created_at) DESC;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_notes_full(uuid) TO anon, authenticated;

-- Insert (p_id NULL) or update one note. An update only matches a row whose
-- popup_id equals p_popup_id, so a note can never be moved to another event.
-- p_plain is the plain-text copy stored in `note`.
CREATE OR REPLACE FUNCTION public.popup_notes_save(p_id uuid, p_popup_id uuid, p_body_html text, p_plain text)
 RETURNS TABLE(id uuid, note text, body_html text, written_by_name text, created_at timestamptz, updated_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users; v_id uuid; v_html text; v_plain text;
BEGIN
  me := require_admin_session();
  v_html := coalesce(p_body_html, '');
  v_plain := coalesce(p_plain, '');
  -- Server-side allowlist: only b, strong, i, em, u, ul, ol, li, br, div, p, span
  -- may appear as tags. The kiosk sanitises too; this is the backstop.
  IF v_html ~* '<(?!/?(b|strong|i|em|u|ul|ol|li|br|div|p|span)[\s>/])' THEN RAISE EXCEPTION 'bad_html'; END IF;
  IF length(v_html) > 50000 OR length(v_plain) > 20000 THEN RAISE EXCEPTION 'note_too_long'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO popup_notes(popup_id, note, body_html, written_by, written_by_name, updated_at)
      VALUES (p_popup_id, v_plain, v_html, me.id, me.display_name, now())
      RETURNING popup_notes.id INTO v_id;
  ELSE
    UPDATE popup_notes
       SET note = v_plain, body_html = v_html, updated_at = now()
     WHERE popup_notes.id = p_id AND popup_notes.popup_id = p_popup_id
     RETURNING popup_notes.id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'note_not_found'; END IF;
  END IF;
  RETURN QUERY
    SELECT n.id, n.note, n.body_html, n.written_by_name, n.created_at, n.updated_at
    FROM popup_notes n WHERE n.id = v_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_notes_save(uuid, uuid, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
