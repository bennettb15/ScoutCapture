insert into storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
values (
    'scoutcapture-originals',
    'scoutcapture-originals',
    false,
    null,
    array['image/heic', 'image/heif', 'image/jpeg', 'image/png']
)
on conflict (id) do nothing;
