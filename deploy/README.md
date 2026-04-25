# First-deploy checklist on the server:

- [ ] useradd -r -s /sbin/nologin burpee_trainer
- [ ] mkdir -p /var/lib/burpee_trainer /etc/burpee_trainer
- [ ] cp deploy/env.example /etc/burpee_trainer/env  # then fill in values
- [ ] chmod 600 /etc/burpee_trainer/env
- [ ] cp deploy/burpee_trainer.service /etc/systemd/system/
- [ ] systemctl daemon-reload && systemctl enable burpee_trainer
