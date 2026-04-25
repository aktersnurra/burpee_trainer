# First-deploy checklist on the server:

- [x] useradd -r -s /sbin/nologin burpee_trainer
- [x] mkdir -p /var/lib/burpee_trainer /etc/burpee_trainer
- [x] cp deploy/env.example /etc/burpee_trainer/env  # then fill in values
- [x] chmod 600 /etc/burpee_trainer/env
- [x] cp deploy/burpee_trainer.service /etc/systemd/system/
- [x] systemctl daemon-reload && systemctl enable burpee_trainer
