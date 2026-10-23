#!/bin/bash
# T02 PROVISIONAL synthetic STT set (TTS audio, not real calls). Real gate set = bench/ar-sa (T02a).
# Writes bench/synth/{ar,en}/NN.wav (16 kHz mono, gitignored) + NN.txt (reference, committed).
# Usage: bench/make-synth-set.sh   (macOS only: needs `say` + `afconvert`)
set -euo pipefail
cd "$(dirname "$0")"
AR_VOICE="${AR_VOICE:-Majed}"   # ar_001 (MSA voice; sentences are Saudi white dialect)
EN_VOICE="${EN_VOICE:-Samantha}"

AR=(
"نحتاج نحدد سعر الباقة الشهرية قبل الإطلاق"
"كم عدد العملاء اللي سجلوا في الفترة التجريبية"
"الفريق الحين فيه خمسة مطورين ومصممة وحدة"
"متى تبون تطلقون النسخة الأولى من التطبيق"
"وش الفرق بين الباقة الأساسية والباقة المتقدمة"
"نبي نوصل لألف مشترك قبل نهاية السنة"
"هل عندكم خطة للتوسع في دول الخليج"
"السيرفرات حقتنا على AWS في منطقة البحرين"
"نستخدم API خارجي للدفع الإلكتروني"
"كيف تحمون بيانات العملاء الشخصية"
"التكلفة الشهرية للتشغيل تقريبا عشرين ألف ريال"
"عندنا dashboard يعرض المبيعات بشكل مباشر"
"ليش اخترتوا هذا السوق بالذات"
"المستثمرين طلبوا نموذج مالي لثلاث سنوات"
"نقدر نسوي integration مع أنظمة المحاسبة"
"وين مقر الشركة الرئيسي"
"الإطلاق الرسمي بيكون في الربع الأول"
"مين المنافسين الرئيسيين لكم في السعودية"
"نشتغل بنظام SaaS باشتراك سنوي"
"تقدر تشرح لي كيف يشتغل التطبيق من البداية"
)
EN=(
"What is the monthly price of the pro plan"
"We plan to launch the beta in January"
"How many engineers are on the team right now"
"Our backend runs on Postgres and Redis"
"Can you explain how the onboarding flow works"
"We closed our seed round three months ago"
"The churn rate dropped to four percent last quarter"
"Do you support single sign on for enterprise customers"
"Our main competitor charges twice as much"
"When will the mobile app be available"
)

render() { # voice text out_base
  mkdir -p "$(dirname "$3")"
  printf '%s\n' "$2" > "$3.txt"
  say -v "$1" -o "$3.aiff" "$2"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$3.aiff" "$3.wav"
  rm -f "$3.aiff"
}
for i in "${!AR[@]}"; do render "$AR_VOICE" "${AR[$i]}" "synth/ar/$(printf %02d $((i+1)))"; done
for i in "${!EN[@]}"; do render "$EN_VOICE" "${EN[$i]}" "synth/en/$(printf %02d $((i+1)))"; done
echo "synth: $(ls synth/ar/*.wav | wc -l | tr -d ' ') ar, $(ls synth/en/*.wav | wc -l | tr -d ' ') en clips"
