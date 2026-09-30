#!/bin/sh
# Synthetic 3-voice French conversation (macOS `say` voices) → audio/t###.wav + audio/turns.txt
set -e
cd "$(dirname "$0")"; mkdir -p audio; rm -f audio/turns.txt; i=0
while IFS='|' read -r v t; do
  i=$((i+1)); f=$(printf "%03d" $i)
  say -v "$v" -o "audio/t$f.wav" --file-format=WAVE --data-format=LEF32@16000 "$t"
  echo "$f|$v" >> audio/turns.txt
done <<'LINES'
Thomas|Bonjour tout le monde, alors qu'est-ce qu'on mange ce soir, vous avez une idée ?
Flo (Français (France))|Moi je voudrais bien des pâtes, ça fait longtemps qu'on n'en a pas mangé.
Jacques|Des pâtes encore ? On en a mangé mardi dernier il me semble.
Thomas|Bon d'accord, et si on faisait un poisson avec des légumes du marché ?
Flo (Français (France))|Oui pourquoi pas, mais il faut aller au marché avant midi alors.
Jacques|Je peux y aller demain matin, j'ai le temps après ma course.
Thomas|Parfait, prends aussi du pain et un peu de fromage s'il te plaît.
Flo (Français (France))|Et pour le dessert on fait quoi ? Une tarte aux pommes ?
Jacques|Ah oui, la tarte de mamie, c'est la meilleure.
Thomas|Tu penses qu'on pourrait inviter les voisins samedi soir ?
Flo (Français (France))|Ils sont partis en vacances jusqu'à la fin du mois, je crois.
Jacques|Dommage, on les invitera à leur retour alors.
Thomas|Bon, on se retrouve à la maison vers dix-neuf heures ?
Flo (Français (France))|Ça marche, je m'occupe de mettre la table.
Jacques|Et moi je fais la vaisselle, promis cette fois.
Thomas|Tu dis ça à chaque fois et c'est toujours moi qui la fais !
Flo (Français (France))|Allez, on va tous s'y mettre, ce sera plus rapide.
Jacques|D'accord, d'accord, je m'y mets tout de suite après le repas.
LINES
