#!/bin/sh
# Synthetic voices for test_earshot.py. Daniel = you, Karen = Maya, Aman = Arjun, Albert = stranger.
cd "$(dirname "$0")/testdata" || exit 1
g() { say -v "$1" -o "$2.wav" --data-format=LEI16@16000 "$3"; }
g Daniel me_enroll "The quick brown fox jumps over the lazy dog. I am recording my own voice so the app knows when I am the one talking, and it can ignore me."
g Daniel me_1 "Nice to meet you. I'm a freshman at Cornell studying information science, and I build hardware hackathon projects."
g Karen maya_intro "Hi, I'm Maya Chen, I'm a product manager at Stripe working on the payments platform team."
g Karen maya_2 "We just launched a new checkout flow for small businesses and I'm hiring summer interns next month."
g Karen maya_later "Hey, good to see you again! How did that hackathon go in the end?"
g Aman arjun_intro "Honestly the hardest part of legged robots is the contact model, we spend months on it at Carnegie Mellon."
g Aman arjun_later "Oh hello again, are you still working on those smart glasses?"
g Albert stranger "Does anyone know where the coffee is? I have been looking for twenty minutes."
