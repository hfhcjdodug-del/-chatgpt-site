-- شغّل هذا إذا كنت شغّلت schema.sql سابقاً (يزيل قيد المفتاح الأجنبي عن messages.conv_id)
alter table public.messages drop constraint if exists messages_conv_id_fkey;
